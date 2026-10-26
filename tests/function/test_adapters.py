"""T-014: adaptadores reales detrás de los puertos (tablas, HTTP, reloj, configuración), sin red."""

from datetime import UTC

import pytest
import requests
from azure.core import MatchConditions
from azure.core.exceptions import (
    HttpResponseError,
    ResourceExistsError,
    ResourceModifiedError,
    ResourceNotFoundError,
)
from azure.data.tables import UpdateMode

from function.core.clock import SystemClock
from function.core.http_transport import RequestsTransport
from function.core.ports import EntityExists, EtagMismatch, TransportError
from function.core.settings import ConfigurationError, load_settings
from function.core.table_repo import AzureTableStore

from .conftest import FakeCredential

# --- Tablas ---


class Entity(dict):
    def __init__(self, data, etag):
        super().__init__(data)
        self.metadata = {"etag": etag}


class FakeTableClient:
    def __init__(self):
        self.rows = {}
        self.update_error = None
        self.last_update = None

    def get_entity(self, pk, rk):
        if (pk, rk) not in self.rows:
            raise ResourceNotFoundError("no existe")
        return Entity(self.rows[(pk, rk)], 'W/"1"')

    def create_entity(self, entity):
        key = (entity["PartitionKey"], entity["RowKey"])
        if key in self.rows:
            raise ResourceExistsError("existe")
        self.rows[key] = dict(entity)
        return {"etag": 'W/"1"'}

    def update_entity(self, entity, mode, etag, match_condition):
        self.last_update = (mode, etag, match_condition)
        if self.update_error:
            raise self.update_error
        return {"etag": 'W/"2"'}

    def query_entities(self, query_filter, parameters, select):
        assert query_filter == "PartitionKey eq @pk"
        return [r for (p, _), r in self.rows.items() if p == parameters["pk"]]


class FakeService:
    def __init__(self):
        self.clients = {}

    def get_table_client(self, name):
        return self.clients.setdefault(name, FakeTableClient())


@pytest.fixture
def table():
    service = FakeService()
    return AzureTableStore(service), service


def test_table_get_insert_count(table):
    store, service = table
    assert store.get("dedup", "p", "r") is None
    assert store.insert("dedup", {"PartitionKey": "p", "RowKey": "r", "x": 1}) == 'W/"1"'
    entity, etag = store.get("dedup", "p", "r")
    assert entity["x"] == 1 and etag == 'W/"1"'
    with pytest.raises(EntityExists):
        store.insert("dedup", {"PartitionKey": "p", "RowKey": "r"})
    assert store.count_partition("dedup", "p") == 1
    assert service.get_table_client("dedup") is service.clients["dedup"]


def test_table_update_uses_if_match(table):
    store, service = table
    assert store.update("dedup", {"PartitionKey": "p", "RowKey": "r"}, 'W/"1"') == 'W/"2"'
    assert service.clients["dedup"].last_update == (UpdateMode.MERGE, 'W/"1"', MatchConditions.IfNotModified)
    store.update("dedup", {"PartitionKey": "p", "RowKey": "r"}, 'W/"1"', replace=True)
    assert service.clients["dedup"].last_update[0] == UpdateMode.REPLACE


@pytest.mark.parametrize("error", [ResourceModifiedError("412"), ResourceNotFoundError("404")])
def test_table_update_conflicts_map_to_etag_mismatch(table, error):
    store, service = table
    service.get_table_client("dedup").update_error = error
    with pytest.raises(EtagMismatch):
        store.update("dedup", {"PartitionKey": "p", "RowKey": "r"}, "e")


def test_table_update_412_http_error_maps_to_etag_mismatch(table):
    store, service = table
    error = HttpResponseError("412")
    error.status_code = 412
    service.get_table_client("dedup").update_error = error
    with pytest.raises(EtagMismatch):
        store.update("dedup", {"PartitionKey": "p", "RowKey": "r"}, "e")


def test_table_other_errors_propagate(table):
    store, service = table
    error = HttpResponseError("500")
    error.status_code = 500
    service.get_table_client("dedup").update_error = error
    with pytest.raises(HttpResponseError):
        store.update("dedup", {"PartitionKey": "p", "RowKey": "r"}, "e")


def test_table_from_endpoint_builds_a_service_client():
    store = AzureTableStore.from_endpoint("https://cuenta-ficticia.table.core.windows.net", FakeCredential())
    assert store is not None


# --- HTTP ---


class FakeResponse:
    def __init__(self, status, body=None, text="", headers=None):
        self.status_code = status
        self._body = body
        self.text = text
        self.headers = headers or {}

    def json(self):
        if self._body is None:
            raise ValueError("sin json")
        return self._body


class FakeSession:
    def __init__(self, result):
        self.result = result
        self.kwargs = None

    def request(self, method, url, **kwargs):
        self.kwargs = {"method": method, "url": url, **kwargs}
        if isinstance(self.result, Exception):
            raise self.result
        return self.result


def test_http_returns_json_body_and_headers():
    session = FakeSession(FakeResponse(201, {"id": "1"}, headers={"Retry-After": "1"}))
    response = RequestsTransport(session).request(
        "POST", "https://x.example", headers={"a": "b"}, json={}, timeout=3
    )
    assert response.status == 201
    assert response.body == {"id": "1"}
    assert response.header("retry-after") == "1"
    assert session.kwargs["timeout"] == 3


def test_http_non_json_body_falls_back_to_text():
    response = RequestsTransport(FakeSession(FakeResponse(202, text=""))).request("POST", "https://x.example")
    assert response.body is None
    response = RequestsTransport(FakeSession(FakeResponse(500, text="error"))).request(
        "GET", "https://x.example"
    )
    assert response.body == "error"


@pytest.mark.parametrize("error", [requests.Timeout("t"), requests.ConnectionError("c")])
def test_http_network_errors_become_transport_error(error):
    with pytest.raises(TransportError):
        RequestsTransport(FakeSession(error)).request("GET", "https://x.example")


def test_http_default_session():
    assert isinstance(RequestsTransport()._session, requests.Session)


# --- Reloj ---


def test_system_clock(monkeypatch):
    clock = SystemClock()
    assert clock.now().tzinfo == UTC
    assert clock.monotonic() <= clock.monotonic()
    slept = []
    monkeypatch.setattr("function.core.clock.time.sleep", slept.append)
    clock.sleep(0.5)
    assert slept == [0.5]


# --- Configuración ---

BASE_ENV = {
    "DSA_GRAPH_SITE_ID": "sitio-ficticio",
    "DSA_GRAPH_LIST_ID": "lista-ficticia",
    "DSA_FLOW_URL": "https://flujo-ficticio.example/invoke",
    "DSA_TABLE_ENDPOINT": "https://cuenta-ficticia.table.core.windows.net",
    "AZURE_CLIENT_ID": "00000000-0000-0000-0000-000000000000",
}


def test_settings_defaults():
    settings = load_settings(BASE_ENV)
    assert settings.max_incidents_per_minute == 10
    assert settings.test_device_id == "preflight-01"
    assert settings.window_seconds == 60
    assert settings.site_id == "sitio-ficticio"


def test_settings_overrides():
    settings = load_settings({**BASE_ENV, "DSA_MAX_INCIDENTS_PER_MINUTE": "3", "DSA_TEST_DEVICE_ID": "otro"})
    assert settings.max_incidents_per_minute == 3
    assert settings.test_device_id == "otro"


def test_settings_table_endpoint_fallbacks():
    env = {k: v for k, v in BASE_ENV.items() if k != "DSA_TABLE_ENDPOINT"}
    uri = "https://c.table.core.windows.net"
    assert load_settings({**env, "AzureWebJobsStorage__tableServiceUri": uri}).table_endpoint == uri
    assert (
        load_settings({**env, "AzureWebJobsStorage__accountName": "cuenta"}).table_endpoint
        == "https://cuenta.table.core.windows.net"
    )


def test_settings_missing_names_are_listed_without_values():
    with pytest.raises(ConfigurationError) as info:
        load_settings({"DSA_FLOW_URL": "https://secreto.example"})
    message = str(info.value)
    assert "DSA_GRAPH_SITE_ID" in message and "AZURE_CLIENT_ID" in message and "DSA_TABLE_ENDPOINT" in message
    assert "secreto" not in message


@pytest.mark.parametrize("value", ["cero", "0", "-1"])
def test_settings_invalid_limit(value):
    with pytest.raises(ConfigurationError):
        load_settings({**BASE_ENV, "DSA_MAX_INCIDENTS_PER_MINUTE": value})
