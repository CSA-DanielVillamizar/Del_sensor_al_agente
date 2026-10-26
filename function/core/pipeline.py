"""Orquestación de ADR-004 §1, sin bindings: validar → ventana → límite → enriquecer → Graph → flujo.

Orden de efectos: Table Storage (candado de la ventana) → Graph (registro de auditoría) → flujo
(agente). Cada paso es idempotente ante reentregas: la cabecera de la ventana guarda
`quotaTaken`, `itemId` y `flowTriggered` y solo se hace lo que falta.

Errores (ADR-004 §2):
- Evento inválido o zona desconocida → `EventRejected`, sin excepción (CA-05.3).
- Graph 4xx distinto de 429 → `GraphRejected`, sin excepción (reintentar no ayuda).
- Flujo 401/403 → `AgentTriggerAuthFailed`, sin excepción; el incidente queda en `Nuevo` y
  `demo/retrigger` lo recupera.
- Presupuesto de Graph agotado, flujo sin respuesta tras 3 intentos, conflicto de concurrencia
  o repetición antes de que exista el elemento → excepción, y entra el reintento del runtime.
"""

from __future__ import annotations

import json
from dataclasses import dataclass
from datetime import UTC, datetime
from typing import Any

from .contracts import Contracts
from .dedup import STATE_DISCARDED, Claim, DedupWindow
from .enrich import EnrichedEvent, UnknownZone, ZoneCatalog, enrich
from .flow_trigger import FlowAuthRejected, FlowTrigger, FlowTriggerRejected
from .graph_client import GraphClient, GraphRejected
from .listitem import ColumnContract, build_create_fields, iso_utc_ms, repetitions_fields
from .ports import Clock, TableStore
from .ratelimit import DEFAULT_MAX_PER_MINUTE, RateLimiter
from .telemetry import Telemetry
from .validation import safe_event_id, validate_event


class WindowNotReady(Exception):
    """Repetición de una ventana cuyo elemento aún no existe; se reintenta (ADR-004, paso 7)."""


@dataclass(frozen=True)
class PipelineSettings:
    max_incidents_per_minute: int = DEFAULT_MAX_PER_MINUTE
    window_seconds: int = 60
    test_device_id: str = "preflight-01"


@dataclass(frozen=True)
class Outcome:
    name: str
    event_id: str | None = None
    incident_event_id: str | None = None
    item_id: str | None = None


class IngestPipeline:
    def __init__(
        self,
        *,
        contracts: Contracts,
        store: TableStore,
        graph: GraphClient,
        flow: FlowTrigger,
        clock: Clock,
        telemetry: Telemetry,
        settings: PipelineSettings | None = None,
    ) -> None:
        settings = settings or PipelineSettings()
        self._validator = contracts.event_validator
        self._catalog = ZoneCatalog(contracts.zones)
        self._columns = ColumnContract(contracts.columns)
        self._dedup = DedupWindow(store, window_seconds=settings.window_seconds)
        self._limiter = RateLimiter(store, max_per_minute=settings.max_incidents_per_minute)
        self._graph = graph
        self._flow = flow
        self._clock = clock
        self._log = telemetry
        self._test_device_id = settings.test_device_id

    # --- Punto de entrada del binding ---

    def run(
        self,
        body: bytes,
        *,
        enqueued_utc: datetime | None,
        connection_device_id: str | None,
        retry_count: int,
        max_retry_count: int,
    ) -> Outcome:
        """Procesa y decide qué hacer con una excepción: relanzarla mientras queden reintentos
        del runtime, o registrar `EventFailed` y terminar en el último."""
        try:
            return self.process(body, enqueued_utc=enqueued_utc, connection_device_id=connection_device_id)
        except Exception as exc:
            event_id = safe_event_id(_peek(body))
            last = retry_count >= max_retry_count
            self._log.emit(
                "EventFailed",
                eventId=event_id,
                step="run",
                outcome="gave_up" if last else "retrying",
                error=type(exc).__name__,
                retryCount=retry_count,
                maxRetryCount=max_retry_count,
            )
            if not last:
                raise
            return Outcome("EventFailed", event_id=event_id)

    def process(
        self, body: bytes, *, enqueued_utc: datetime | None, connection_device_id: str | None
    ) -> Outcome:
        enqueued = _as_utc(enqueued_utc) if enqueued_utc else self._clock.now()

        # 1. Validar (y 4. enriquecer, que es puro: una zona desconocida es un evento inválido).
        result = validate_event(body, self._validator)
        if not result.ok:
            return self._reject(result.event_id, result.reason)
        try:
            event = enrich(result.event, self._catalog)
        except UnknownZone:
            return self._reject(result.event_id, "zone: fuera del catálogo")

        # 2. Reclamar la ventana.
        claim = self._dedup.claim(
            event_id=event.event_id, device_id=event.device_id, type=event.type, enqueued_utc=enqueued
        )
        if claim.kind == "late":
            self._emit(
                "RepetitionCounted",
                event,
                claim,
                step="claim",
                outcome="late_ignored",
                enqueuedTimeUtc=iso_utc_ms(enqueued),
            )
            return Outcome("RepetitionCounted", event.event_id, claim.window.window_id)
        if claim.window.state == STATE_DISCARDED:
            self._emit("IncidentDiscarded", event, claim, step="claim", outcome="window_discarded")
            return Outcome("IncidentDiscarded", event.event_id, claim.window.window_id)
        if claim.is_opener:
            return self._open_incident(event, claim, enqueued, connection_device_id)
        return self._count_repetition(event, claim)

    # --- Pasos ---

    def _open_incident(
        self, event: EnrichedEvent, claim: Claim, enqueued: datetime, connection_device_id: str | None
    ) -> Outcome:
        header = claim.window
        incident_id = header.window_id

        # 3. Límite por minuto, una sola vez por ventana.
        if not header.quota_taken:
            if not self._limiter.try_take(self._clock.now()):
                self._dedup.update(header, event.device_id, event.type, state=STATE_DISCARDED)
                self._emit("IncidentDiscarded", event, claim, step="ratelimit", outcome="rate_limited")
                return Outcome("IncidentDiscarded", event.event_id, incident_id)
            header = self._dedup.update(header, event.device_id, event.type, quota_taken=True)

        # 5. Crear el elemento (registro de auditoría) antes de disparar al agente.
        if header.item_id is None:
            fields = build_create_fields(
                event,
                received_utc=enqueued,
                is_test=connection_device_id == self._test_device_id,
                contract=self._columns,
            )
            try:
                created = self._graph.create_item(fields)
            except GraphRejected as exc:
                self._emit(
                    "GraphRejected",
                    event,
                    claim,
                    step="create",
                    outcome="rejected",
                    status=exc.status,
                    code=exc.code,
                )
                return Outcome("GraphRejected", event.event_id, incident_id)
            graph_created = self._clock.now()
            self._emit(
                "IncidentCreated",
                event,
                claim,
                step="create",
                outcome="existing" if created.existing else "created",
                itemId=created.item_id,
                enqueuedTimeUtc=iso_utc_ms(enqueued),
                graphCreatedUtc=iso_utc_ms(graph_created),
                durationMs=int((graph_created - enqueued).total_seconds() * 1000),
                isTest=fields["EsPrueba"],
            )
            header = self._dedup.update(header, event.device_id, event.type, item_id=created.item_id)

        # 6. Disparar al agente con el eventId del primer evento de la ventana.
        if header.flow_triggered:
            return Outcome("IncidentCreated", event.event_id, incident_id, header.item_id)
        try:
            result = self._flow.trigger(incident_id)
        except FlowAuthRejected as exc:
            self._emit(
                "AgentTriggerAuthFailed",
                event,
                claim,
                step="trigger",
                outcome="unauthorized",
                status=exc.status,
                target=self._flow.safe_target,
            )
            return Outcome("AgentTriggerAuthFailed", event.event_id, incident_id, header.item_id)
        except FlowTriggerRejected as exc:
            self._emit(
                "EventFailed",
                event,
                claim,
                step="trigger",
                outcome="flow_rejected",
                status=exc.status,
                target=self._flow.safe_target,
            )
            return Outcome("EventFailed", event.event_id, incident_id, header.item_id)
        self._emit(
            "AgentTriggered",
            event,
            claim,
            step="trigger",
            outcome="accepted",
            status=result.status,
            attempts=result.attempts,
            itemId=header.item_id,
        )
        self._dedup.update(header, event.device_id, event.type, flow_triggered=True)
        return Outcome("AgentTriggered", event.event_id, incident_id, header.item_id)

    def _count_repetition(self, event: EnrichedEvent, claim: Claim) -> Outcome:
        # 7. Repeticiones = filas de la ventana; no consume cupo del límite (CA-02.2).
        header = claim.window
        if header.item_id is None:
            raise WindowNotReady(f"La ventana {header.window_id} aún no tiene elemento")
        count = self._dedup.repetitions(header.window_id)
        try:
            self._graph.update_fields(header.item_id, repetitions_fields(count, self._columns))
        except GraphRejected as exc:
            self._emit(
                "GraphRejected",
                event,
                claim,
                step="repetition",
                outcome="rejected",
                status=exc.status,
                code=exc.code,
            )
            return Outcome("GraphRejected", event.event_id, header.window_id, header.item_id)
        self._emit(
            "RepetitionCounted",
            event,
            claim,
            step="repetition",
            outcome="redelivery" if claim.redelivery else "counted",
            repetitions=count,
            itemId=header.item_id,
        )
        return Outcome("RepetitionCounted", event.event_id, header.window_id, header.item_id)

    # --- Registros ---

    def _reject(self, event_id: str | None, reason: str | None) -> Outcome:
        self._log.emit("EventRejected", eventId=event_id, step="validate", outcome="invalid", reason=reason)
        return Outcome("EventRejected", event_id)

    def _emit(self, name: str, event: EnrichedEvent, claim: Claim, **fields: Any) -> None:
        self._log.emit(
            name,
            eventId=event.event_id,
            incidentEventId=claim.window.window_id,
            deviceId=event.device_id,
            type=event.type,
            **fields,
        )


def _as_utc(value: datetime) -> datetime:
    return value.replace(tzinfo=UTC) if value.tzinfo is None else value.astimezone(UTC)


def _peek(body: bytes) -> Any:
    """Lee el cuerpo solo para correlacionar un fallo; nunca lanza."""
    try:
        return json.loads(body)
    except Exception:  # noqa: BLE001 - es solo para el registro
        return None
