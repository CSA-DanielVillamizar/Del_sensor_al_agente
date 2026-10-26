"""T-013 HU-08 CA-08.6: disparo del flujo con el token de la identidad; 3 intentos; 401/403 sin reintento.

Revisión obligatoria del revisor-seguridad (RS): el token nunca aparece en registros ni en errores.
"""

import logging

import pytest

from function.core.flow_trigger import (
    FLOW_SCOPE,
    FlowAuthRejected,
    FlowTrigger,
    FlowTriggerFailed,
    FlowTriggerRejected,
)

from .conftest import FAKE_TOKEN, FakeClock, FakeCredential, FakeTransport, resp, timeout_error

# URL ficticia de un disparador con autenticación de Entra ID (sin firma SAS).
FLOW_URL = "https://flujo-ficticio.example/workflows/abc/triggers/manual/paths/invoke?api-version=1"
EVENT_ID = "3f2b8a4e-6c1d-4e9a-9f7b-2d5c8e1a0b37"


def make(responses):
    transport = FakeTransport(responses=list(responses))
    clock = FakeClock()
    credential = FakeCredential()
    return FlowTrigger(transport, credential, clock, flow_url=FLOW_URL), transport, clock, credential


def test_scope_has_double_slash_for_trailing_slash_audience():
    # ADR-007: audiencia https://service.flow.microsoft.com/ → alcance con doble barra.
    assert FLOW_SCOPE == "https://service.flow.microsoft.com//.default"


def test_posts_only_the_event_id_with_bearer_token():
    trigger, transport, _clock, credential = make([resp(202)])
    result = trigger.trigger(EVENT_ID)
    assert result.status == 202
    assert result.attempts == 1
    call = transport.calls[0]
    assert call.method == "POST"
    assert call.url == FLOW_URL
    assert call.json == {"eventId": EVENT_ID}
    assert call.headers["Authorization"] == f"Bearer {FAKE_TOKEN}"
    assert call.timeout == 10.0
    assert credential.scopes == [FLOW_SCOPE]


@pytest.mark.parametrize("status", [401, 403])
def test_auth_errors_are_not_retried(status):
    trigger, transport, clock, _cred = make([resp(status)])
    with pytest.raises(FlowAuthRejected) as info:
        trigger.trigger(EVENT_ID)
    assert info.value.status == status
    assert len(transport.calls) == 1
    assert clock.sleeps == []


@pytest.mark.parametrize("status", [400, 404])
def test_other_4xx_is_not_retried(status):
    trigger, transport, _clock, _cred = make([resp(status)])
    with pytest.raises(FlowTriggerRejected):
        trigger.trigger(EVENT_ID)
    assert len(transport.calls) == 1


def test_transient_errors_are_retried_up_to_three_attempts():
    trigger, transport, clock, _cred = make([resp(429), timeout_error(), resp(202)])
    result = trigger.trigger(EVENT_ID)
    assert result.attempts == 3
    assert clock.sleeps == [1.0, 2.0]
    assert len(transport.calls) == 3


def test_raises_after_the_third_attempt():
    trigger, transport, clock, _cred = make([resp(500), resp(503), resp(502)])
    with pytest.raises(FlowTriggerFailed):
        trigger.trigger(EVENT_ID)
    assert len(transport.calls) == 3
    assert clock.sleeps == [1.0, 2.0]


@pytest.mark.parametrize(
    "url",
    [
        "http://flujo-ficticio.example/invoke",
        "https://flujo-ficticio.example/invoke?sp=x&sv=1.0&sig=FIRMA",
        "",
    ],
)
def test_rejects_insecure_or_sas_urls(url):
    with pytest.raises(ValueError):
        FlowTrigger(FakeTransport(), FakeCredential(), FakeClock(), flow_url=url)


def test_rejects_non_uuid_event_id():
    trigger, transport, _clock, _cred = make([])
    with pytest.raises(ValueError):
        trigger.trigger("Ana Perez")
    assert transport.calls == []


def test_safe_target_never_includes_path_or_query():
    trigger, *_ = make([])
    assert trigger.safe_target == "flujo-ficticio.example"


def test_token_never_logged_or_in_errors(caplog):
    caplog.set_level(logging.DEBUG)
    trigger, *_ = make([resp(401, {"echo": FAKE_TOKEN}), resp(500), resp(500), resp(500)])
    with pytest.raises(FlowAuthRejected) as auth:
        trigger.trigger(EVENT_ID)
    with pytest.raises(FlowTriggerFailed) as failed:
        trigger.trigger(EVENT_ID)
    for text in (str(auth.value), repr(auth.value), str(failed.value), caplog.text):
        assert FAKE_TOKEN not in text
        assert "Bearer" not in text
