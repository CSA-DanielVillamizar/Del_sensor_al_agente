"""T-007 HU-05 CA-05.3: un evento inválido produce un rechazo, nunca una excepción."""

import json

import pytest

from function.core.contracts import load_contracts
from function.core.validation import validate_event

from .conftest import VALID_EVENT

CONTRACTS = load_contracts()


def check(body):
    return validate_event(body, CONTRACTS.event_validator)


def test_valid_event_from_bytes():
    result = check(json.dumps(VALID_EVENT).encode("utf-8"))
    assert result.ok
    assert result.event == VALID_EVENT
    assert result.event_id == VALID_EVENT["eventId"]
    assert result.reason is None


def test_valid_event_from_str():
    assert check(json.dumps(VALID_EVENT)).ok


@pytest.mark.parametrize("body", [b"no es json", b"", b"\xff\xfe", b"[1, 2]", b"null"])
def test_unparseable_or_non_object_body_is_rejected(body):
    result = check(body)
    assert not result.ok
    assert result.event_id is None
    assert result.reason


def test_schema_violation_is_rejected_with_event_id():
    body = json.dumps({**VALID_EVENT, "zone": "Bodega"})
    result = check(body)
    assert not result.ok
    assert result.event_id == VALID_EVENT["eventId"]
    assert "zone" in result.reason


def test_reason_never_echoes_the_offending_value():
    # Art. 4: el motivo no repite el valor recibido, que podría traer un dato personal.
    body = json.dumps({**VALID_EVENT, "deviceId": "Ana Perez", "personName": "Ana Perez"})
    result = check(body)
    assert not result.ok
    assert "Ana" not in result.reason


def test_malformed_event_id_is_not_reported():
    body = json.dumps({**VALID_EVENT, "eventId": "Ana Perez"})
    result = check(body)
    assert not result.ok
    assert result.event_id is None
