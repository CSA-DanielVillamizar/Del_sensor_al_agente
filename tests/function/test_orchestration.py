"""T-014 HU-05, HU-06, HU-12 (CA-05.3, CA-05.4, CA-12.1, CA-02.2, RNF-04): orquestación de ADR-004 con dobles.

Orden de efectos: Table → Graph → flujo. Ningún doble toca Azure, Graph ni Power Automate.
"""

import json
import logging
from datetime import timedelta

import pytest

from function.core.contracts import load_contracts
from function.core.dedup import TABLE as DEDUP
from function.core.flow_trigger import FlowTrigger, FlowTriggerFailed
from function.core.graph_client import GraphClient
from function.core.pipeline import IngestPipeline, PipelineSettings, WindowNotReady
from function.core.telemetry import Telemetry

from .conftest import FAKE_TOKEN, T0, VALID_EVENT, FakeClock, FakeCredential, FakeTransport, event_id, resp

SITE, LIST = "sitio-ficticio", "lista-ficticia"
FLOW_URL = "https://flujo-ficticio.example/invoke"
CONTRACTS = load_contracts()


class Harness:
    def __init__(self, max_per_minute=10):
        from .conftest import InMemoryTableStore

        self.log: list[str] = []
        self.store = InMemoryTableStore()
        self.clock = FakeClock()
        self.graph_http = FakeTransport(on_call=lambda t: self.log.append(f"graph:{t.calls[-1].method}"))
        self.flow_http = FakeTransport(on_call=lambda t: self.log.append("flow"))
        original = {
            name: getattr(self.store, name) for name in ("get", "insert", "update", "count_partition")
        }
        for name, fn in original.items():
            setattr(self.store, name, self._traced(name, fn))
        self.logger = logging.getLogger("dsa.orchestration")
        credential = FakeCredential()
        self.pipeline = IngestPipeline(
            contracts=CONTRACTS,
            store=self.store,
            graph=GraphClient(
                self.graph_http, credential, self.clock, site_id=SITE, list_id=LIST, jitter=lambda: 0.0
            ),
            flow=FlowTrigger(self.flow_http, credential, self.clock, flow_url=FLOW_URL),
            clock=self.clock,
            telemetry=Telemetry(self.logger),
            settings=PipelineSettings(max_incidents_per_minute=max_per_minute),
        )

    def _traced(self, name, fn):
        def wrapper(table, *args, **kwargs):
            self.log.append(f"table:{name}:{table}")
            return fn(table, *args, **kwargs)

        return wrapper

    def send(self, event=None, seconds=0.0, device="sim-01", **overrides):
        event = {**VALID_EVENT, **(event or {}), **overrides}
        body = json.dumps(event).encode("utf-8")
        return self.pipeline.process(
            body, enqueued_utc=T0 + timedelta(seconds=seconds), connection_device_id=device
        )


def records(caplog, name=None):
    out = []
    for record in caplog.records:
        n, _, payload = record.getMessage().partition(" ")
        if name is None or n == name:
            out.append(json.loads(payload))
    return out


@pytest.fixture
def h(caplog):
    caplog.set_level(logging.INFO, logger="dsa.orchestration")
    return Harness()


def test_new_event_order_is_table_then_graph_then_flow(h, caplog):
    h.graph_http.responses = [resp(201, {"id": "17"})]
    h.flow_http.responses = [resp(202)]
    outcome = h.send()
    assert outcome.name == "AgentTriggered"
    assert outcome.item_id == "17"

    first_graph = h.log.index("graph:POST")
    flow = h.log.index("flow")
    assert all(entry.startswith("table:") for entry in h.log[:first_graph])
    assert first_graph < flow
    # itemId se guarda en la ventana antes de llamar al flujo; flowTriggered después.
    assert "table:update:dedup" in h.log[first_graph:flow]
    assert h.log[-1] == "table:update:dedup"

    body = h.graph_http.calls[0].json["fields"]
    assert body["Estado"] == "Nuevo"
    assert body["EventId"] == VALID_EVENT["eventId"]
    assert body["RecibidoUtc"] == "2026-11-04T19:32:06.000Z"
    assert body["EsPrueba"] is False
    assert h.flow_http.calls[0].json == {"eventId": VALID_EVENT["eventId"]}

    created = records(caplog, "IncidentCreated")[0]
    assert created["eventId"] == created["incidentEventId"] == VALID_EVENT["eventId"]
    assert created["outcome"] == "created"
    assert created["enqueuedTimeUtc"] == "2026-11-04T19:32:06.000Z"
    assert "graphCreatedUtc" in created and "durationMs" in created
    assert records(caplog, "AgentTriggered")[0]["eventId"] == VALID_EVENT["eventId"]


def test_preflight_device_marks_test_incident(h):
    h.graph_http.responses = [resp(201, {"id": "1"})]
    h.flow_http.responses = [resp(202)]
    h.send(device="preflight-01")
    assert h.graph_http.calls[0].json["fields"]["EsPrueba"] is True


@pytest.mark.parametrize(
    "body",
    [
        b"no es json",
        json.dumps({**VALID_EVENT, "personName": "Ana"}).encode(),
        json.dumps({**VALID_EVENT, "zone": "Z-99"}).encode(),
    ],
)
def test_invalid_event_is_rejected_without_exception_or_side_effects(h, caplog, body):
    outcome = h.pipeline.process(body, enqueued_utc=T0, connection_device_id="sim-01")
    assert outcome.name == "EventRejected"
    assert h.log == []
    rejected = records(caplog, "EventRejected")[0]
    assert rejected["step"] == "validate"
    assert "Ana" not in caplog.text


def test_burst_of_20_creates_one_incident_and_patches_repetitions(h, caplog):
    # CA-02.2 con límite 1: las repeticiones no consumen cupo.
    h = Harness(max_per_minute=1)
    h.graph_http.responses = [resp(201, {"id": "17"})] + [resp(200, {})] * 19
    h.flow_http.responses = [resp(202)]
    outcomes = [h.send(eventId=event_id(n), seconds=n * 0.4) for n in range(1, 21)]
    assert [o.name for o in outcomes].count("AgentTriggered") == 1
    assert [o.name for o in outcomes].count("RepetitionCounted") == 19
    patches = [c for c in h.graph_http.calls if c.method == "PATCH"]
    assert patches[-1].json == {"Repeticiones": 20}
    assert patches[-1].url.endswith("/items/17/fields")
    assert len(h.flow_http.calls) == 1
    assert h.store.get("ratelimit", "minute", "202611041932")[0]["count"] == 1


def test_eleventh_incident_of_the_minute_is_discarded_and_logged(h, caplog):
    h.graph_http.responses = [resp(201, {"id": str(n)}) for n in range(10)]
    h.flow_http.responses = [resp(202)] * 10
    outcomes = [h.send(eventId=event_id(n), deviceId=f"DEV-SIM-{n:02d}") for n in range(11)]
    assert [o.name for o in outcomes] == ["AgentTriggered"] * 10 + ["IncidentDiscarded"]
    discarded = records(caplog, "IncidentDiscarded")[0]
    assert discarded["eventId"] == event_id(10)
    assert discarded["outcome"] == "rate_limited"
    header = h.store.get(DEDUP, "DEV-SIM-10|puerta_forzada", "current")[0]
    assert header["state"] == "discarded"
    # Las repeticiones de una ventana descartada también se descartan y se registran.
    again = h.send(eventId=event_id(99), deviceId="DEV-SIM-10", seconds=5)
    assert again.name == "IncidentDiscarded"
    assert records(caplog, "IncidentDiscarded")[-1]["outcome"] == "window_discarded"
    assert len(h.graph_http.calls) == 10


def test_redelivery_of_opener_does_not_create_or_trigger_again(h, caplog):
    h.graph_http.responses = [resp(201, {"id": "17"})]
    h.flow_http.responses = [resp(202)]
    h.send()
    outcome = h.send()
    assert outcome.name == "IncidentCreated"
    assert outcome.item_id == "17"
    assert len(h.graph_http.calls) == 1
    assert len(h.flow_http.calls) == 1
    assert h.store.get("ratelimit", "minute", "202611041932")[0]["count"] == 1


def test_flow_failure_raises_and_retry_only_retriggers(h):
    h.graph_http.responses = [resp(201, {"id": "17"})]
    h.flow_http.responses = [resp(500)] * 3
    with pytest.raises(FlowTriggerFailed):
        h.send()
    h.flow_http.responses = [resp(202)]
    outcome = h.send()  # reintento del runtime con el mismo evento
    assert outcome.name == "AgentTriggered"
    assert len([c for c in h.graph_http.calls if c.method == "POST"]) == 1


def test_crash_between_create_and_saving_item_id_recovers_by_event_id(h):
    h.graph_http.responses = [resp(201, {"id": "17"})]

    def crash(_store):
        raise RuntimeError("caída simulada")

    # Actualizaciones de la cabecera: 1.ª quotaTaken, 2.ª itemId. La caída ocurre en la 2.ª,
    # después de que Graph creó el elemento.
    h.store.before_update.extend([lambda s: None, crash])
    with pytest.raises(RuntimeError):
        h.send()
    h.graph_http.responses = [
        resp(409, {"error": {"code": "conflict", "message": "unique"}}),
        resp(200, {"value": [{"id": "17"}]}),
    ]
    h.flow_http.responses = [resp(202)]
    outcome = h.send()
    assert outcome.name == "AgentTriggered"
    assert outcome.item_id == "17"


def test_graph_rejection_is_logged_and_flow_not_called(h, caplog):
    h.graph_http.responses = [resp(403, {"error": {"code": "accessDenied"}})]
    outcome = h.send()
    assert outcome.name == "GraphRejected"
    assert h.flow_http.calls == []
    rejected = records(caplog, "GraphRejected")[0]
    assert rejected["status"] == 403 and rejected["eventId"] == VALID_EVENT["eventId"]


def test_graph_rejection_on_repetition_is_logged(h, caplog):
    h.graph_http.responses = [resp(201, {"id": "17"}), resp(404, {"error": {"code": "itemNotFound"}})]
    h.flow_http.responses = [resp(202)]
    h.send()
    outcome = h.send(eventId=event_id(2), seconds=3)
    assert outcome.name == "GraphRejected"
    assert records(caplog, "GraphRejected")[0]["step"] == "repetition"


def test_flow_auth_failure_is_logged_and_incident_stays_new(h, caplog):
    h.graph_http.responses = [resp(201, {"id": "17"})]
    h.flow_http.responses = [resp(401)]
    outcome = h.send()
    assert outcome.name == "AgentTriggerAuthFailed"
    failed = records(caplog, "AgentTriggerAuthFailed")[0]
    assert failed["status"] == 401
    assert failed["target"] == "flujo-ficticio.example"
    assert not h.store.get(DEDUP, "DEV-SIM-01|puerta_forzada", "current")[0]["flowTriggered"]


def test_flow_other_4xx_is_logged_as_failure_without_retry(h, caplog):
    h.graph_http.responses = [resp(201, {"id": "17"})]
    h.flow_http.responses = [resp(404)]
    outcome = h.send()
    assert outcome.name == "EventFailed"
    assert records(caplog, "EventFailed")[0]["outcome"] == "flow_rejected"


def test_repetition_before_item_exists_raises_for_runtime_retry(h):
    h.graph_http.responses = [resp(503)] * 4
    with pytest.raises(Exception):  # noqa: B017 - el presupuesto de Graph se agota
        h.send()
    with pytest.raises(WindowNotReady):
        h.send(eventId=event_id(2), seconds=2)


def test_late_event_is_ignored_and_logged(h, caplog):
    h.graph_http.responses = [resp(201, {"id": "1"}), resp(201, {"id": "2"})]
    h.flow_http.responses = [resp(202), resp(202)]
    h.send(eventId=event_id(1), seconds=0)
    h.send(eventId=event_id(2), seconds=70)
    outcome = h.send(eventId=event_id(3), seconds=30)
    assert outcome.name == "RepetitionCounted"
    assert records(caplog, "RepetitionCounted")[-1]["outcome"] == "late_ignored"
    assert len(h.graph_http.calls) == 2


def test_naive_enqueued_time_is_treated_as_utc(h):
    h.graph_http.responses = [resp(201, {"id": "1"})]
    h.flow_http.responses = [resp(202)]
    body = json.dumps(VALID_EVENT).encode()
    h.pipeline.process(body, enqueued_utc=T0.replace(tzinfo=None), connection_device_id=None)
    assert h.graph_http.calls[0].json["fields"]["RecibidoUtc"] == "2026-11-04T19:32:06.000Z"


def test_missing_enqueued_time_falls_back_to_clock(h):
    h.graph_http.responses = [resp(201, {"id": "1"})]
    h.flow_http.responses = [resp(202)]
    h.pipeline.process(json.dumps(VALID_EVENT).encode(), enqueued_utc=None, connection_device_id=None)
    assert h.graph_http.calls[0].json["fields"]["RecibidoUtc"] == "2026-11-04T19:32:06.000Z"


def test_token_never_logged(h, caplog):
    h.graph_http.responses = [resp(201, {"id": "1"})]
    h.flow_http.responses = [resp(401, {"echo": FAKE_TOKEN})]
    h.send()
    assert FAKE_TOKEN not in caplog.text


# --- run(): decisión ante una excepción no controlada (política del runtime, ADR-004 §2) ---


def test_run_reraises_while_retries_remain(h, caplog):
    h.graph_http.responses = [resp(201, {"id": "17"})]
    h.flow_http.responses = [resp(500)] * 3
    body = json.dumps(VALID_EVENT).encode()
    with pytest.raises(FlowTriggerFailed):
        h.pipeline.run(body, enqueued_utc=T0, connection_device_id=None, retry_count=0, max_retry_count=3)
    failed = records(caplog, "EventFailed")[-1]
    assert failed["outcome"] == "retrying"
    assert failed["eventId"] == VALID_EVENT["eventId"]
    assert failed["error"] == "FlowTriggerFailed"


def test_run_gives_up_on_last_retry_without_raising(h, caplog):
    h.graph_http.responses = [resp(201, {"id": "17"})]
    h.flow_http.responses = [resp(500)] * 3
    body = json.dumps(VALID_EVENT).encode()
    outcome = h.pipeline.run(
        body, enqueued_utc=T0, connection_device_id=None, retry_count=3, max_retry_count=3
    )
    assert outcome.name == "EventFailed"
    assert records(caplog, "EventFailed")[-1]["outcome"] == "gave_up"


def test_run_returns_outcome_on_success(h):
    h.graph_http.responses = [resp(201, {"id": "17"})]
    h.flow_http.responses = [resp(202)]
    body = json.dumps(VALID_EVENT).encode()
    outcome = h.pipeline.run(
        body, enqueued_utc=T0, connection_device_id=None, retry_count=0, max_retry_count=3
    )
    assert outcome.name == "AgentTriggered"
