"""T-012 HU-06 CA-06.1: cliente de Graph (ADR-004 §2).

Retry-After, tope de 6 s y choque con la unicidad de EventId.
"""

import pytest

from function.core.graph_client import GRAPH_SCOPE, GraphClient, GraphRejected, GraphRetryBudgetExceeded

from .conftest import FAKE_TOKEN, FakeClock, FakeCredential, FakeTransport, resp, timeout_error

SITE, LIST = "contoso-ficticio.example,site-guid,web-guid", "list-guid"
EVENT_ID = "3f2b8a4e-6c1d-4e9a-9f7b-2d5c8e1a0b37"
ITEMS_URL = f"https://graph.microsoft.com/v1.0/sites/{SITE}/lists/{LIST}/items"


def make(responses, budget=6.0):
    transport = FakeTransport(responses=list(responses))
    clock = FakeClock()
    credential = FakeCredential()
    client = GraphClient(
        transport, credential, clock, site_id=SITE, list_id=LIST, budget_seconds=budget, jitter=lambda: 0.0
    )
    return client, transport, clock, credential


def test_create_posts_fields_with_bearer_token():
    client, transport, _clock, credential = make([resp(201, {"id": "17"})])
    created = client.create_item({"EventId": EVENT_ID})
    assert created.item_id == "17"
    assert not created.existing
    call = transport.calls[0]
    assert call.method == "POST"
    assert call.url == ITEMS_URL
    assert call.json == {"fields": {"EventId": EVENT_ID}}
    assert call.headers["Authorization"] == f"Bearer {FAKE_TOKEN}"
    assert credential.scopes == [GRAPH_SCOPE]
    assert GRAPH_SCOPE == "https://graph.microsoft.com/.default"


def test_update_patches_fields():
    client, transport, _clock, _cred = make([resp(200, {"Repeticiones": 3})])
    client.update_fields("17", {"Repeticiones": 3})
    call = transport.calls[0]
    assert call.method == "PATCH"
    assert call.url == f"{ITEMS_URL}/17/fields"
    assert call.json == {"Repeticiones": 3}


def test_429_with_retry_after_waits_exactly_that():
    client, transport, clock, _cred = make([resp(429, headers={"Retry-After": "2"}), resp(201, {"id": "1"})])
    assert client.create_item({}).item_id == "1"
    assert clock.sleeps == [2.0]
    assert len(transport.calls) == 2


def test_503_without_header_uses_exponential_backoff():
    client, _t, clock, _cred = make([resp(503), resp(503), resp(503), resp(201, {"id": "1"})])
    client.create_item({})
    assert clock.sleeps == [0.5, 1.0, 2.0]


def test_jitter_is_added_to_backoff():
    transport = FakeTransport(responses=[resp(503), resp(201, {"id": "1"})])
    clock = FakeClock()
    client = GraphClient(transport, FakeCredential(), clock, site_id=SITE, list_id=LIST, jitter=lambda: 1.0)
    client.create_item({})
    assert 0.5 < clock.sleeps[0] <= 0.75


def test_retry_after_beyond_budget_raises_without_sleeping():
    client, _t, clock, _cred = make([resp(429, headers={"Retry-After": "10"})])
    with pytest.raises(GraphRetryBudgetExceeded):
        client.create_item({})
    assert clock.sleeps == []


def test_budget_of_six_seconds_is_respected():
    client, _t, clock, _cred = make([resp(429, headers={"Retry-After": "3"})] * 5)
    with pytest.raises(GraphRetryBudgetExceeded):
        client.create_item({})
    assert sum(clock.sleeps) <= 6.0
    assert clock.sleeps == [3.0, 3.0]


def test_backoff_gives_up_after_three_retries():
    client, transport, _clock, _cred = make([resp(503)] * 5)
    with pytest.raises(GraphRetryBudgetExceeded):
        client.create_item({})
    assert len(transport.calls) == 4


def test_transport_error_is_retried():
    client, _t, clock, _cred = make([timeout_error(), resp(201, {"id": "1"})])
    assert client.create_item({}).item_id == "1"
    assert clock.sleeps == [0.5]


@pytest.mark.parametrize("status", [400, 401, 403, 404])
def test_other_4xx_is_not_retried(status):
    client, transport, clock, _cred = make(
        [resp(status, {"error": {"code": "accessDenied", "message": "x"}})]
    )
    with pytest.raises(GraphRejected) as info:
        client.create_item({})
    assert info.value.status == status
    assert info.value.code == "accessDenied"
    assert len(transport.calls) == 1
    assert clock.sleeps == []


def test_unique_conflict_finds_existing_item():
    # R-14: el código exacto no está documentado; 409 o 400 con "unique" se tratan como choque.
    client, transport, _clock, _cred = make(
        [
            resp(409, {"error": {"code": "nameAlreadyExists", "message": "duplicate"}}),
            resp(200, {"value": [{"id": "42"}]}),
        ]
    )
    created = client.create_item({"EventId": EVENT_ID})
    assert created.item_id == "42"
    assert created.existing
    find = transport.calls[1]
    assert find.method == "GET"
    assert "fields/EventId%20eq%20%27" + EVENT_ID in find.url


def test_unique_conflict_reported_as_400():
    client, _t, _clock, _cred = make(
        [
            resp(
                400,
                {"error": {"code": "invalidRequest", "message": "The list item must have a unique value."}},
            ),
            resp(200, {"value": [{"id": "43"}]}),
        ]
    )
    assert client.create_item({"EventId": EVENT_ID}).item_id == "43"


def test_unique_conflict_without_existing_item_is_rejected():
    client, _t, _clock, _cred = make([resp(409, {"error": {"code": "conflict"}}), resp(200, {"value": []})])
    with pytest.raises(GraphRejected):
        client.create_item({"EventId": EVENT_ID})


def test_find_returns_none_when_absent():
    client, _t, _clock, _cred = make([resp(200, {"value": []})])
    assert client.find_item_by_event_id(EVENT_ID) is None


def test_find_rejects_non_uuid():
    client, _t, _clock, _cred = make([])
    with pytest.raises(ValueError):
        client.find_item_by_event_id("x' or 1 eq 1")


def test_token_never_appears_in_errors():
    client, _t, _clock, _cred = make([resp(403, {"error": {"code": "accessDenied", "message": FAKE_TOKEN}})])
    with pytest.raises(GraphRejected) as info:
        client.create_item({})
    assert FAKE_TOKEN not in str(info.value)
    assert FAKE_TOKEN not in repr(info.value)


def test_non_json_error_body_is_handled():
    client, _t, _clock, _cred = make([resp(403, "texto")])
    with pytest.raises(GraphRejected) as info:
        client.create_item({})
    assert info.value.code is None


def test_unparseable_retry_after_falls_back_to_backoff():
    client, _t, clock, _cred = make([resp(429, headers={"Retry-After": "mañana"}), resp(201, {"id": "1"})])
    client.create_item({})
    assert clock.sleeps == [0.5]
