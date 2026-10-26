"""T-014: `function_app.py` solo orquesta; `host.json` conserva todos los registros (CA-05.5, R-G4)."""

import importlib
import json
import sys
from datetime import UTC, datetime
from pathlib import Path

import azure.functions as func
import pytest

FUNCTION_DIR = Path(__file__).resolve().parents[2] / "function"


@pytest.fixture(scope="module")
def function_app():
    # La Function se despliega desde function/: allí `core` es un paquete de primer nivel.
    sys.path.insert(0, str(FUNCTION_DIR))
    try:
        yield importlib.import_module("function_app")
    finally:
        sys.path.remove(str(FUNCTION_DIR))


@pytest.fixture(scope="module")
def indexed(function_app):
    # get_functions() indexa la app y solo se puede llamar una vez por importación.
    (fn,) = function_app.app.get_functions()
    return fn


def test_single_function_with_iot_hub_trigger(indexed):
    data = json.loads(indexed.get_function_json())
    assert data["scriptFile"] == "function_app.py"
    (trigger,) = data["bindings"]
    assert trigger["type"] == "eventHubTrigger"
    assert trigger["connection"] == "IoTHubConnection"
    assert trigger["consumerGroup"] == "func"
    assert trigger["cardinality"].lower() == "one"


def test_retry_policy_matches_adr_004(indexed):
    retry = indexed.get_setting("retry_policy").get_dict_repr()
    assert retry["strategy"] == "exponential_backoff"
    assert str(retry["max_retry_count"]) == "3"
    assert retry["minimum_interval"] == "00:00:05"
    assert retry["maximum_interval"] == "00:00:30"


class FakePipeline:
    def __init__(self):
        self.kwargs = None

    def run(self, body, **kwargs):
        self.kwargs = {"body": body, **kwargs}


class RetryContext:
    retry_count = 1
    max_retry_count = 3


class Context:
    retry_context = RetryContext()


def test_handler_passes_trigger_data_to_the_pipeline(function_app, monkeypatch):
    fake = FakePipeline()
    monkeypatch.setattr(function_app, "_pipeline", lambda: fake)
    enqueued = datetime(2026, 11, 4, 19, 32, 6, tzinfo=UTC)
    event = func.EventHubEvent(
        body=b'{"x": 1}', enqueued_time=enqueued, iothub_metadata={"connection-device-id": "preflight-01"}
    )
    function_app.ingest_event(event, Context())
    assert fake.kwargs == {
        "body": b'{"x": 1}',
        "enqueued_utc": enqueued,
        "connection_device_id": "preflight-01",
        "retry_count": 1,
        "max_retry_count": 3,
    }


def test_handler_without_retry_context_or_metadata(function_app, monkeypatch):
    fake = FakePipeline()
    monkeypatch.setattr(function_app, "_pipeline", lambda: fake)

    class NoRetry:
        retry_context = None

    function_app.ingest_event(func.EventHubEvent(body=b"{}"), NoRetry())
    assert fake.kwargs["connection_device_id"] is None
    assert fake.kwargs["retry_count"] == 0
    assert fake.kwargs["enqueued_utc"] is None


def test_build_pipeline_fails_clearly_without_settings(function_app, monkeypatch):
    from core.settings import ConfigurationError

    for name in (
        "DSA_GRAPH_SITE_ID",
        "DSA_GRAPH_LIST_ID",
        "DSA_FLOW_URL",
        "DSA_TABLE_ENDPOINT",
        "AZURE_CLIENT_ID",
    ):
        monkeypatch.delenv(name, raising=False)
    function_app._pipeline.cache_clear()
    with pytest.raises(ConfigurationError):
        function_app._pipeline()


def test_build_pipeline_with_fictitious_settings_makes_no_calls(function_app, monkeypatch):
    monkeypatch.setenv("DSA_GRAPH_SITE_ID", "sitio-ficticio")
    monkeypatch.setenv("DSA_GRAPH_LIST_ID", "lista-ficticia")
    monkeypatch.setenv("DSA_FLOW_URL", "https://flujo-ficticio.example/invoke")
    monkeypatch.setenv("DSA_TABLE_ENDPOINT", "https://cuenta-ficticia.table.core.windows.net")
    monkeypatch.setenv("AZURE_CLIENT_ID", "00000000-0000-0000-0000-000000000000")
    function_app._pipeline.cache_clear()
    try:
        assert function_app._pipeline() is function_app._pipeline()
    finally:
        function_app._pipeline.cache_clear()


# --- host.json ---

HOST = json.loads((FUNCTION_DIR / "host.json").read_text(encoding="utf-8"))


def test_host_json_disables_application_insights_sampling():
    # CA-05.5 y hallazgo R-G4 de docs/gobernanza.md: la medición del tramo 1 necesita todas las trazas.
    assert HOST["logging"]["applicationInsights"]["samplingSettings"]["isEnabled"] is False


def test_host_json_uses_extension_bundle_v4():
    assert HOST["version"] == "2.0"
    assert HOST["extensionBundle"]["id"] == "Microsoft.Azure.Functions.ExtensionBundle"
    assert HOST["extensionBundle"]["version"] == "[4.*, 5.0.0)"


def test_host_json_quiets_sdk_http_logs():
    # Los SDK registran cada petición HTTP con sus encabezados: ruido que consume el límite diario
    # de Log Analytics y oculta los registros de medición (CA-05.5).
    levels = HOST["logging"]["logLevel"]
    assert levels.get("Azure.Core") == "Warning"
    assert levels.get("Azure.Messaging.EventHubs") == "Warning"


def test_python_sdk_loggers_are_quieted(function_app):
    import logging

    assert logging.getLogger("azure").getEffectiveLevel() >= logging.WARNING
