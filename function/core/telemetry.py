"""Registros estructurados con `eventId` como identificador de correlación (RNF-04, plan §7).

Cada registro es una línea `"{Nombre} {json}"` que llega a Application Insights como traza;
la consulta KQL del tramo 1 (`infra/queries/tramo1.kql`) la lee con
`parse_json(substring(message, indexof(message, " ") + 1))`. El mismo diccionario viaja en
`custom_dimensions` por si se activa el exportador de OpenTelemetry.

Para el tramo 1 cuenta solo `IncidentCreated` con `outcome = "created"`.

Defensa en profundidad: solo se aceptan campos conocidos y escalares, y cualquier valor con
forma de token (JWT o `Bearer ...`) se redacta. El token nunca debe llegar aquí.
"""

from __future__ import annotations

import json
import logging
import re
from typing import Any

EVENT_NAMES = frozenset(
    {
        "EventRejected",
        "IncidentCreated",
        "RepetitionCounted",
        "IncidentDiscarded",
        "AgentTriggered",
        "AgentTriggerAuthFailed",
        "GraphRejected",
        "EventFailed",
    }
)

_LEVELS = {
    "EventRejected": logging.WARNING,
    "IncidentDiscarded": logging.WARNING,
    "GraphRejected": logging.WARNING,
    "AgentTriggerAuthFailed": logging.ERROR,
    "EventFailed": logging.ERROR,
}

ALLOWED_FIELDS = frozenset(
    {
        "eventId",
        "incidentEventId",
        "deviceId",
        "type",
        "step",
        "outcome",
        "enqueuedTimeUtc",
        "graphCreatedUtc",
        "durationMs",
        "itemId",
        "repetitions",
        "status",
        "code",
        "reason",
        "attempts",
        "isTest",
        "target",
        "error",
        "retryCount",
        "maxRetryCount",
    }
)

_TOKENISH = re.compile(r"(Bearer\s+\S+|eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+)")
REDACTED = "[redactado]"


def _clean(value: Any) -> Any:
    if isinstance(value, str):
        return _TOKENISH.sub(REDACTED, value)
    return value


class Telemetry:
    def __init__(self, logger: logging.Logger) -> None:
        self._logger = logger

    def emit(self, name: str, **fields: Any) -> dict[str, Any]:
        if name not in EVENT_NAMES:
            raise ValueError(f"Nombre de evento no previsto: {name}")
        unknown = set(fields) - ALLOWED_FIELDS
        if unknown:
            raise ValueError(f"Campos de registro no previstos: {sorted(unknown)}")
        record: dict[str, Any] = {"name": name}
        for key, value in fields.items():
            if value is None:
                continue
            if not isinstance(value, str | int | float | bool):
                raise ValueError(f"El campo {key} debe ser escalar")
            record[key] = _clean(value)
        message = f"{name} {json.dumps(record, ensure_ascii=False, sort_keys=True)}"
        self._logger.log(_LEVELS.get(name, logging.INFO), message, extra={"custom_dimensions": record})
        return record
