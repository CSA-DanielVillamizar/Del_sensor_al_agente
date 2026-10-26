"""T-014 RNF-04: registros estructurados con eventId; nunca un token."""

import json
import logging

import pytest

from function.core.telemetry import EVENT_NAMES, Telemetry

from .conftest import FAKE_TOKEN


@pytest.fixture
def telemetry(caplog):
    caplog.set_level(logging.DEBUG, logger="dsa.test")
    return Telemetry(logging.getLogger("dsa.test"))


def parse(record):
    name, _, payload = record.getMessage().partition(" ")
    return name, json.loads(payload)


def test_event_names_match_plan_7():
    assert EVENT_NAMES == {
        "EventRejected",
        "IncidentCreated",
        "RepetitionCounted",
        "IncidentDiscarded",
        "AgentTriggered",
        "AgentTriggerAuthFailed",
        "GraphRejected",
        "EventFailed",
    }


def test_record_is_json_with_event_id(telemetry, caplog):
    telemetry.emit(
        "IncidentCreated",
        eventId="e1",
        incidentEventId="e1",
        step="create",
        outcome="created",
        deviceId="DEV-SIM-01",
        type="puerta_forzada",
        itemId="17",
        durationMs=1234,
    )
    name, data = parse(caplog.records[-1])
    assert name == "IncidentCreated"
    assert data["name"] == "IncidentCreated"
    assert data["eventId"] == "e1"
    assert data["durationMs"] == 1234
    assert caplog.records[-1].custom_dimensions == data
    assert caplog.records[-1].levelno == logging.INFO


def test_none_values_are_dropped(telemetry, caplog):
    telemetry.emit("EventRejected", eventId=None, step="validate", outcome="invalid", reason="x")
    _name, data = parse(caplog.records[-1])
    assert "eventId" not in data


@pytest.mark.parametrize(
    "name,level",
    [
        ("EventRejected", logging.WARNING),
        ("GraphRejected", logging.WARNING),
        ("AgentTriggerAuthFailed", logging.ERROR),
        ("EventFailed", logging.ERROR),
        ("RepetitionCounted", logging.INFO),
    ],
)
def test_levels(telemetry, caplog, name, level):
    telemetry.emit(name, eventId="e", step="s", outcome="o")
    assert caplog.records[-1].levelno == level


def test_unknown_name_or_field_is_a_programming_error(telemetry):
    with pytest.raises(ValueError):
        telemetry.emit("Otro", eventId="e")
    with pytest.raises(ValueError):
        telemetry.emit("EventFailed", eventId="e", token="x")
    with pytest.raises(ValueError):
        telemetry.emit("EventFailed", eventId="e", reason={"nested": 1})


@pytest.mark.parametrize("value", [FAKE_TOKEN, f"Bearer {FAKE_TOKEN}", f"falló con {FAKE_TOKEN}"])
def test_token_like_values_are_redacted(telemetry, caplog, value):
    telemetry.emit("EventFailed", eventId="e", step="s", outcome="o", reason=value)
    assert FAKE_TOKEN not in caplog.text
    _name, data = parse(caplog.records[-1])
    assert "[redactado]" in data["reason"]
