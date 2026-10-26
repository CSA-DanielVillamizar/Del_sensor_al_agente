"""T-005 HU-01 CA-01.1, CA-01.3: el generador de mensajes produce eventos que cumplen el esquema."""

import re
import uuid
from datetime import UTC, datetime

import pytest

from simulator.message import (
    DEFAULT_SEVERITY,
    EVENT_TYPES,
    EventValidationError,
    build_event,
    validate_event,
)

EXPECTED_FIELDS = {"schemaVersion", "eventId", "deviceId", "type", "zone", "timestamp", "rawSeverity"}


def test_supports_exactly_three_types():
    assert set(EVENT_TYPES) == {"movimiento_zona_restringida", "puerta_forzada", "acceso_denegado_repetido"}


@pytest.mark.parametrize("event_type", EVENT_TYPES)
def test_event_of_each_type_is_valid_against_schema(event_type, validator):
    event = build_event(event_type, "Z-03", "DEV-SIM-01")
    assert list(validator.iter_errors(event)) == []
    assert event["type"] == event_type


def test_event_has_only_schema_fields():
    event = build_event("puerta_forzada", "Z-03", "DEV-SIM-01")
    assert set(event) == EXPECTED_FIELDS
    assert event["schemaVersion"] == "1.0"
    assert event["zone"] == "Z-03"
    assert event["deviceId"] == "DEV-SIM-01"


def test_event_id_is_uuid_v4_and_unique():
    ids = {build_event("puerta_forzada", "Z-03", "DEV-SIM-01")["eventId"] for _ in range(50)}
    assert len(ids) == 50
    for value in ids:
        assert uuid.UUID(value).version == 4


def test_timestamp_is_iso_8601_utc_with_z():
    fixed = datetime(2026, 11, 4, 19, 32, 5, 123456, tzinfo=UTC)
    event = build_event("puerta_forzada", "Z-03", "DEV-SIM-01", now=lambda: fixed)
    assert event["timestamp"] == "2026-11-04T19:32:05.123Z"
    assert re.fullmatch(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z", event["timestamp"])


def test_default_severity_depends_on_type():
    for event_type in EVENT_TYPES:
        event = build_event(event_type, "Z-01", "DEV-SIM-01")
        assert event["rawSeverity"] == DEFAULT_SEVERITY[event_type]


def test_explicit_severity_is_used():
    event = build_event("puerta_forzada", "Z-01", "DEV-SIM-01", severity="Crítica")
    assert event["rawSeverity"] == "Crítica"


def test_validate_event_accepts_valid_event():
    validate_event(build_event("puerta_forzada", "Z-03", "DEV-SIM-01"))


@pytest.mark.parametrize(
    "field, value",
    [
        ("zone", "Bodega norte"),
        ("deviceId", "Juan Perez"),
        ("type", "intrusion"),
        ("rawSeverity", "Urgente"),
        ("timestamp", "2026-11-04 19:32:05"),
    ],
)
def test_validate_event_rejects_out_of_pattern_values(field, value):
    event = build_event("puerta_forzada", "Z-03", "DEV-SIM-01")
    event[field] = value
    with pytest.raises(EventValidationError) as info:
        validate_event(event)
    assert field in str(info.value)


def test_validate_event_rejects_personal_data_field():
    event = build_event("puerta_forzada", "Z-03", "DEV-SIM-01")
    event["personName"] = "Nombre de ejemplo"
    with pytest.raises(EventValidationError):
        validate_event(event)
