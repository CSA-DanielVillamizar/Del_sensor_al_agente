"""Paso 1 de ADR-004: validar el cuerpo contra el esquema del evento (CA-05.3).

Nunca lanza excepción por un evento inválido: devuelve un rechazo con un motivo que no
repite el valor recibido (podría traer un dato personal, Art. 4).
"""

from __future__ import annotations

import json
import re
from dataclasses import dataclass
from typing import Any

from jsonschema import Draft202012Validator

_UUID = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$")


@dataclass(frozen=True)
class ValidationResult:
    ok: bool
    event: dict[str, Any] | None = None
    event_id: str | None = None
    reason: str | None = None


def safe_event_id(candidate: Any) -> str | None:
    """Devuelve el eventId solo si tiene forma de UUID; así nunca se registra texto libre."""
    if isinstance(candidate, dict):
        candidate = candidate.get("eventId")
    if isinstance(candidate, str) and _UUID.match(candidate):
        return candidate
    return None


def validate_event(body: bytes | str, validator: Draft202012Validator) -> ValidationResult:
    try:
        text = body.decode("utf-8") if isinstance(body, bytes | bytearray) else body
        data = json.loads(text)
    except (UnicodeDecodeError, json.JSONDecodeError):
        return ValidationResult(ok=False, reason="cuerpo: no es JSON UTF-8")

    if not isinstance(data, dict):
        return ValidationResult(ok=False, reason="cuerpo: no es un objeto JSON")

    errors = sorted(validator.iter_errors(data), key=lambda e: list(e.path))
    if errors:
        # Solo la ruta y la regla incumplida, nunca el valor.
        reason = "; ".join(f"{'/'.join(map(str, e.path)) or '(raíz)'}: {e.validator}" for e in errors[:5])
        return ValidationResult(ok=False, event_id=safe_event_id(data), reason=reason)

    return ValidationResult(ok=True, event=data, event_id=data["eventId"])
