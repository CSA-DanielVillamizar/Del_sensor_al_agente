"""Ventana de deduplicación fija de 60 s en Table Storage (ADR-006, CA-05.2, CA-02.2).

El reloj de referencia es `enqueuedTimeUtc` de IoT Hub, no el `timestamp` del dispositivo.
Modelo en la tabla `dedup`:
- Cabecera `({deviceId}|{type}, current)`: `windowId`, `windowStartUtc`, `state`, `itemId`,
  `flowTriggered` y `quotaTaken`, protegida con ETag.
- Una fila `(w|{windowId}, {eventId})` por evento: su número es `Repeticiones`, idempotente
  ante reentregas.

`quotaTaken` amplía el modelo de ADR-006: deja constancia de que la ventana ya tomó su cupo
del límite por minuto, para que una reentrega del primer evento no consuma un cupo nuevo.
"""

from __future__ import annotations

from dataclasses import dataclass, replace
from datetime import UTC, datetime, timedelta
from typing import Literal

from .ports import EntityExists, EtagMismatch, TableStore

TABLE = "dedup"
HEADER_RK = "current"
STATE_OPEN = "open"
STATE_DISCARDED = "discarded"

ClaimKind = Literal["opened", "repetition", "late"]


class ConcurrencyExhausted(Exception):
    """El bucle de relectura llegó a su máximo; entra el reintento del runtime (ADR-004)."""


class WindowReplaced(Exception):
    """La ventana que se quería actualizar ya fue reemplazada por otra."""


def _iso(value: datetime) -> str:
    return value.astimezone(UTC).strftime("%Y-%m-%dT%H:%M:%S.%fZ")


def _parse(value: str) -> datetime:
    return datetime.fromisoformat(value.replace("Z", "+00:00"))


@dataclass(frozen=True)
class WindowHeader:
    window_id: str
    window_start_utc: datetime
    state: str
    item_id: str | None
    flow_triggered: bool
    quota_taken: bool
    etag: str

    @classmethod
    def from_entity(cls, entity: dict, etag: str) -> WindowHeader:
        return cls(
            window_id=entity["windowId"],
            window_start_utc=_parse(entity["windowStartUtc"]),
            state=entity.get("state", STATE_OPEN),
            item_id=entity.get("itemId") or None,
            flow_triggered=bool(entity.get("flowTriggered", False)),
            quota_taken=bool(entity.get("quotaTaken", False)),
            etag=etag,
        )


@dataclass(frozen=True)
class Claim:
    kind: ClaimKind
    event_id: str
    window: WindowHeader
    redelivery: bool = False

    @property
    def is_opener(self) -> bool:
        return self.kind == "opened"


def header_pk(device_id: str, type_: str) -> str:
    return f"{device_id}|{type_}"


def rows_pk(window_id: str) -> str:
    return f"w|{window_id}"


def _new_header(pk: str, event_id: str, start: datetime) -> dict:
    return {
        "PartitionKey": pk,
        "RowKey": HEADER_RK,
        "windowId": event_id,
        "windowStartUtc": _iso(start),
        "state": STATE_OPEN,
        "itemId": "",
        "flowTriggered": False,
        "quotaTaken": False,
    }


class DedupWindow:
    def __init__(self, store: TableStore, *, window_seconds: float = 60.0, max_attempts: int = 5) -> None:
        self._store = store
        self._window = timedelta(seconds=window_seconds)
        self._max_attempts = max_attempts

    def claim(self, *, event_id: str, device_id: str, type: str, enqueued_utc: datetime) -> Claim:
        pk = header_pk(device_id, type)
        for _ in range(self._max_attempts):
            found = self._store.get(TABLE, pk, HEADER_RK)
            if found is None:
                entity = _new_header(pk, event_id, enqueued_utc)
                try:
                    etag = self._store.insert(TABLE, entity)
                except EntityExists:
                    continue  # otra ejecución ganó: releer
                header = WindowHeader.from_entity(entity, etag)
                kind: ClaimKind = "opened"
            else:
                header = WindowHeader.from_entity(*found)
                elapsed = enqueued_utc - header.window_start_utc
                if header.window_id == event_id:
                    kind = "opened"  # reentrega del primer evento
                elif elapsed >= self._window:
                    entity = _new_header(pk, event_id, enqueued_utc)
                    try:
                        etag = self._store.update(TABLE, entity, header.etag, replace=True)
                    except EtagMismatch:
                        continue  # otra ejecución la reemplazó: releer
                    header = WindowHeader.from_entity(entity, etag)
                    kind = "opened"
                elif elapsed < timedelta(0):
                    # Evento de una ventana ya cerrada que llega tarde (reentrega): no se cuenta.
                    return Claim(kind="late", event_id=event_id, window=header)
                else:
                    kind = "repetition"
            return Claim(
                kind=kind,
                event_id=event_id,
                window=header,
                redelivery=not self._insert_row(header.window_id, event_id, enqueued_utc),
            )
        raise ConcurrencyExhausted(f"dedup: {self._max_attempts} intentos sin resolver la ventana")

    def _insert_row(self, window_id: str, event_id: str, enqueued_utc: datetime) -> bool:
        """Inserta la fila del evento. Devuelve False si ya existía (reentrega)."""
        try:
            self._store.insert(
                TABLE,
                {
                    "PartitionKey": rows_pk(window_id),
                    "RowKey": event_id,
                    "enqueuedTimeUtc": _iso(enqueued_utc),
                },
            )
        except EntityExists:
            return False
        return True

    def update(self, header: WindowHeader, device_id: str, type: str, **changes: object) -> WindowHeader:
        """Fusiona cambios en la cabecera con If-Match; relee ante 412 si sigue siendo la misma ventana."""
        names = {
            "state": "state",
            "item_id": "itemId",
            "flow_triggered": "flowTriggered",
            "quota_taken": "quotaTaken",
        }
        props = {names[k]: v for k, v in changes.items()}
        pk = header_pk(device_id, type)
        current = header
        for _ in range(self._max_attempts):
            entity = {"PartitionKey": pk, "RowKey": HEADER_RK, **props}
            try:
                etag = self._store.update(TABLE, entity, current.etag)
            except EtagMismatch:
                found = self._store.get(TABLE, pk, HEADER_RK)
                if found is None or found[0].get("windowId") != header.window_id:
                    raise WindowReplaced(header.window_id) from None
                current = WindowHeader.from_entity(*found)
                continue
            return replace(current, etag=etag, **changes)
        raise ConcurrencyExhausted(f"dedup: {self._max_attempts} intentos sin actualizar la cabecera")

    def repetitions(self, window_id: str) -> int:
        return self._store.count_partition(TABLE, rows_pk(window_id))
