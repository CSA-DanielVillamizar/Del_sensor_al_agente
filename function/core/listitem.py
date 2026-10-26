"""Cuerpo del elemento de la lista `Eventos de seguridad` (plan §4.3, CA-06.3).

`sharepoint/columnas.json` es la única fuente: este módulo no declara columnas propias, solo
arma los valores y los comprueba contra el contrato antes de enviarlos a Graph.
"""

from __future__ import annotations

import re
from collections.abc import Mapping
from datetime import UTC, datetime
from typing import Any

from .enrich import EnrichedEvent

WRITER = "function"
STATE_NEW = "Nuevo"
_TYPES = {"text", "choice", "number", "dateTime", "boolean", "personOrGroup"}
_ISO_Z = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?Z$")


class ContractViolation(Exception):
    """Un valor no cumple `sharepoint/columnas.json`."""


def iso_utc_ms(value: datetime) -> str:
    """Fecha en UTC con milisegundos y sufijo `Z` (RNF-08)."""
    value = value.astimezone(UTC)
    return value.strftime("%Y-%m-%dT%H:%M:%S.") + f"{value.microsecond // 1000:03d}Z"


class ColumnContract:
    def __init__(self, document: Mapping[str, Any]) -> None:
        self.list_name: str = document["list"]
        self._columns: dict[str, Mapping[str, Any]] = {}
        for column in document["columns"]:
            if column["type"] not in _TYPES:
                raise ContractViolation(f"Tipo de columna no admitido: {column['name']} ({column['type']})")
            self._columns[column["name"]] = column

    def column(self, name: str) -> Mapping[str, Any]:
        try:
            return self._columns[name]
        except KeyError:
            raise ContractViolation(f"Columna fuera del contrato: {name}") from None

    def writable_by(self, writer: str) -> list[str]:
        return [n for n, c in self._columns.items() if writer in c.get("writers", [])]

    def validate(self, fields: Mapping[str, Any], *, writer: str, require_all: bool = False) -> None:
        for name, value in fields.items():
            column = self.column(name)
            if writer not in column.get("writers", []):
                raise ContractViolation(f"{name}: no la escribe {writer}")
            self._check_value(name, column, value)
        if require_all:
            missing = [
                n for n in self.writable_by(writer) if self._columns[n].get("required") and n not in fields
            ]
            if missing:
                raise ContractViolation(f"Faltan columnas obligatorias: {', '.join(missing)}")

    @staticmethod
    def _check_value(name: str, column: Mapping[str, Any], value: Any) -> None:
        kind = column["type"]
        if kind == "choice":
            ok = value in column.get("choices", [])
        elif kind == "number":
            ok = isinstance(value, int) and not isinstance(value, bool)
            if ok and column.get("minimum") is not None:
                ok = value >= column["minimum"]
        elif kind == "dateTime":
            ok = isinstance(value, str) and bool(_ISO_Z.match(value))
        elif kind == "boolean":
            ok = isinstance(value, bool)
        elif kind == "text":
            ok = isinstance(value, str) and (bool(value) or not column.get("required"))
            if ok and column.get("pattern"):
                ok = re.match(column["pattern"], value) is not None
        else:  # personOrGroup: la Function nunca la escribe
            ok = False
        if not ok:
            # Solo el nombre de la columna y el tipo, nunca el valor.
            raise ContractViolation(f"{name}: valor no válido para el tipo {kind}")


def build_create_fields(
    event: EnrichedEvent, *, received_utc: datetime, is_test: bool, contract: ColumnContract
) -> dict[str, Any]:
    """Campos del `POST .../items` (paso 5 de ADR-004)."""
    fields: dict[str, Any] = {
        "Title": f"{event.type} · {event.zone}",
        "EventId": event.event_id,
        "DeviceId": event.device_id,
        "TipoEvento": event.type,
        "Zona": event.zone,
        "NombreZona": event.zone_name,
        "CamaraId": event.camera_id,
        "Sitio": event.site,
        "SeveridadRaw": event.raw_severity,
        "SeveridadInicial": event.initial_severity,
        "Repeticiones": 1,
        "FechaEventoUtc": event.timestamp,
        "RecibidoUtc": iso_utc_ms(received_utc),
        "EsPrueba": is_test,
        "Estado": STATE_NEW,
    }
    contract.validate(fields, writer=WRITER, require_all=True)
    return fields


def repetitions_fields(count: int, contract: ColumnContract) -> dict[str, Any]:
    """Campos del `PATCH .../fields` de una repetición (paso 7 de ADR-004)."""
    fields = {"Repeticiones": count}
    contract.validate(fields, writer=WRITER)
    return fields
