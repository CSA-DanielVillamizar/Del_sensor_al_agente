"""Generador y validador de eventos de dispositivo (T-005, HU-01, CA-01.1, CA-01.3).

El evento solo tiene los campos del esquema `schemas/evento-dispositivo.schema.json`; no hay
campos de texto libre, así que no cabe ningún dato personal (Art. 4).
"""

import json
import uuid
from collections.abc import Callable
from datetime import UTC, datetime
from pathlib import Path

from jsonschema import Draft202012Validator

SCHEMA_PATH = Path(__file__).resolve().parents[1] / "schemas" / "evento-dispositivo.schema.json"
SCHEMA_VERSION = "1.0"

EVENT_TYPES = ("movimiento_zona_restringida", "puerta_forzada", "acceso_denegado_repetido")
SEVERITIES = ("Baja", "Media", "Alta", "Crítica")

# Severidad que reporta el dispositivo si no se indica --severity. La función toma después
# el mayor entre esta y la severidad base de la zona (§5.0).
DEFAULT_SEVERITY = {
    "movimiento_zona_restringida": "Media",
    "puerta_forzada": "Alta",
    "acceso_denegado_repetido": "Media",
}


class EventValidationError(ValueError):
    """El evento no cumple el esquema; no se envía."""


_validator: Draft202012Validator | None = None


def _get_validator() -> Draft202012Validator:
    global _validator
    if _validator is None:
        schema = json.loads(SCHEMA_PATH.read_text(encoding="utf-8"))
        _validator = Draft202012Validator(schema)
    return _validator


def _utc_now() -> datetime:
    return datetime.now(UTC)


def format_timestamp(moment: datetime) -> str:
    """ISO 8601 en UTC con milisegundos y sufijo `Z`."""
    return moment.astimezone(UTC).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def build_event(
    event_type: str,
    zone: str,
    device_id: str,
    severity: str | None = None,
    now: Callable[[], datetime] = _utc_now,
) -> dict:
    """Arma un evento nuevo con `eventId` UUID v4 y marca de tiempo actual."""
    return {
        "schemaVersion": SCHEMA_VERSION,
        "eventId": str(uuid.uuid4()),
        "deviceId": device_id,
        "type": event_type,
        "zone": zone,
        "timestamp": format_timestamp(now()),
        "rawSeverity": severity or DEFAULT_SEVERITY.get(event_type, "Media"),
    }


def validate_event(event: dict) -> None:
    """Lanza `EventValidationError` con todos los errores si el evento no cumple el esquema."""
    errors = sorted(_get_validator().iter_errors(event), key=lambda e: list(e.path))
    if errors:
        details = "; ".join(
            f"{'.'.join(str(p) for p in error.path) or '(raíz)'}: {error.message}" for error in errors
        )
        raise EventValidationError(f"El evento no cumple el esquema: {details}")
