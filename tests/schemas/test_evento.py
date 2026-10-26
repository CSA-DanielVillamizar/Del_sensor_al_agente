"""T-003 HU-01 CA-01.3: el esquema del evento acepta lo válido y rechaza campos extra o fuera de patrón."""

import copy
import json
from pathlib import Path

import pytest
from jsonschema import Draft202012Validator

ROOT = Path(__file__).resolve().parents[2]
SCHEMA = json.loads((ROOT / "schemas" / "evento-dispositivo.schema.json").read_text(encoding="utf-8"))
VALIDATOR = Draft202012Validator(SCHEMA)

VALID = {
    "schemaVersion": "1.0",
    "eventId": "3f2b8a4e-6c1d-4e9a-9f7b-2d5c8e1a0b37",
    "deviceId": "DEV-SIM-01",
    "type": "puerta_forzada",
    "zone": "Z-03",
    "timestamp": "2026-11-04T19:32:05Z",
    "rawSeverity": "Alta",
}


def errors(event):
    return list(VALIDATOR.iter_errors(event))


def test_schema_is_valid_draft_2020_12():
    Draft202012Validator.check_schema(SCHEMA)


def test_valid_event_passes():
    assert errors(VALID) == []


@pytest.mark.parametrize(
    "event_type", ["movimiento_zona_restringida", "puerta_forzada", "acceso_denegado_repetido"]
)
def test_three_supported_types(event_type):
    assert errors({**VALID, "type": event_type}) == []


def test_closed_schema_does_not_allow_extra_fields():
    assert errors({**VALID, "personName": "Ana Pérez"})


@pytest.mark.parametrize(
    "field,value",
    [
        ("deviceId", "Ana Perez"),
        ("deviceId", "dev-sim-01"),
        ("zone", "Bodega"),
        ("zone", "Z-3"),
        ("rawSeverity", "Urgente"),
        ("type", "incendio"),
        ("eventId", "no-es-un-uuid"),
        ("timestamp", "2026-11-04T14:32:05-05:00"),
        ("timestamp", "2026-11-04 19:32:05"),
        ("schemaVersion", "2.0"),
    ],
)
def test_values_out_of_pattern_are_rejected(field, value):
    assert errors({**VALID, field: value})


@pytest.mark.parametrize("field", list(VALID))
def test_every_field_is_required(field):
    event = copy.deepcopy(VALID)
    del event[field]
    assert errors(event)
