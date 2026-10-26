"""Dobles de prueba de la Function: almacén de tablas en memoria, transporte HTTP, credencial y reloj falsos.

Ningún doble toca la red ni Azure (T-007 a T-014).
"""

from __future__ import annotations

import copy
from dataclasses import dataclass, field
from datetime import UTC, datetime, timedelta

from function.core.ports import EntityExists, EtagMismatch, HttpResponse, TransportError

VALID_EVENT = {
    "schemaVersion": "1.0",
    "eventId": "3f2b8a4e-6c1d-4e9a-9f7b-2d5c8e1a0b37",
    "deviceId": "DEV-SIM-01",
    "type": "puerta_forzada",
    "zone": "Z-03",
    "timestamp": "2026-11-04T19:32:05Z",
    "rawSeverity": "Alta",
}

T0 = datetime(2026, 11, 4, 19, 32, 6, tzinfo=UTC)

# Valor ficticio que imita un token; las pruebas comprueban que nunca aparece en los registros.
FAKE_TOKEN = "eyJ0eXAiOiJKV1QiLCJmYWtlIjoidG9rZW4ifQ.ZmFrZQ.ZmFrZQ"


def event_id(n: int) -> str:
    """UUID v4 sintético y determinista para las pruebas."""
    return f"00000000-0000-4000-8000-{n:012d}"


class InMemoryTableStore:
    """Repositorio de tablas en memoria con la semántica de Table Storage: 409 al insertar
    una entidad existente y 412 cuando el ETag no coincide (ADR-006)."""

    def __init__(self) -> None:
        self.tables: dict[str, dict[tuple[str, str], tuple[dict, str]]] = {}
        self._version = 0
        # Ganchos para simular concurrencia: se ejecutan antes de una operación.
        self.before_insert: list = []
        self.before_update: list = []
        self.calls: list[tuple[str, str]] = []

    def _etag(self) -> str:
        self._version += 1
        return f'W/"{self._version}"'

    def get(self, table: str, pk: str, rk: str):
        self.calls.append(("get", table))
        found = self.tables.get(table, {}).get((pk, rk))
        if found is None:
            return None
        entity, etag = found
        return copy.deepcopy(entity), etag

    def insert(self, table: str, entity: dict) -> str:
        self.calls.append(("insert", table))
        if self.before_insert:
            self.before_insert.pop(0)(self)
        rows = self.tables.setdefault(table, {})
        key = (entity["PartitionKey"], entity["RowKey"])
        if key in rows:
            raise EntityExists(table)
        etag = self._etag()
        rows[key] = (copy.deepcopy(entity), etag)
        return etag

    def update(self, table: str, entity: dict, etag: str, *, replace: bool = False) -> str:
        self.calls.append(("update", table))
        if self.before_update:
            self.before_update.pop(0)(self)
        rows = self.tables.setdefault(table, {})
        key = (entity["PartitionKey"], entity["RowKey"])
        current = rows.get(key)
        if current is None or current[1] != etag:
            raise EtagMismatch(table)
        merged = copy.deepcopy(entity) if replace else {**current[0], **copy.deepcopy(entity)}
        new_etag = self._etag()
        rows[key] = (merged, new_etag)
        return new_etag

    def count_partition(self, table: str, pk: str) -> int:
        self.calls.append(("count", table))
        return sum(1 for (p, _r) in self.tables.get(table, {}) if p == pk)

    # Utilidad de prueba: sobrescribe una entidad como si otra instancia la hubiera cambiado.
    def force_put(self, table: str, entity: dict) -> None:
        rows = self.tables.setdefault(table, {})
        rows[(entity["PartitionKey"], entity["RowKey"])] = (copy.deepcopy(entity), self._etag())


class FakeClock:
    """Reloj falso: `sleep` solo avanza el tiempo y lo anota."""

    def __init__(self, start: datetime = T0) -> None:
        self._now = start
        self._mono = 1000.0
        self.sleeps: list[float] = []

    def now(self) -> datetime:
        return self._now

    def monotonic(self) -> float:
        return self._mono

    def sleep(self, seconds: float) -> None:
        self.sleeps.append(seconds)
        self.advance(seconds)

    def advance(self, seconds: float) -> None:
        self._now += timedelta(seconds=seconds)
        self._mono += seconds


@dataclass
class _Token:
    token: str
    expires_on: int = 0


class FakeCredential:
    def __init__(self, token: str = FAKE_TOKEN) -> None:
        self.token = token
        self.scopes: list[str] = []

    def get_token(self, *scopes: str, **_kwargs):
        self.scopes.extend(scopes)
        return _Token(self.token)


@dataclass
class Call:
    method: str
    url: str
    headers: dict
    json: object
    timeout: float


@dataclass
class FakeTransport:
    """Transporte HTTP falso: devuelve respuestas encoladas (o lanza TransportError) y anota cada llamada."""

    responses: list = field(default_factory=list)
    calls: list[Call] = field(default_factory=list)
    on_call: object = None

    def request(self, method, url, *, headers=None, json=None, timeout=10.0):
        self.calls.append(Call(method, url, dict(headers or {}), copy.deepcopy(json), timeout))
        if self.on_call:
            self.on_call(self)
        if not self.responses:
            raise AssertionError(f"Llamada no esperada: {method} {url}")
        nxt = self.responses.pop(0)
        if isinstance(nxt, Exception):
            raise nxt
        return nxt


def resp(status: int, body=None, headers=None) -> HttpResponse:
    return HttpResponse(status=status, headers=dict(headers or {}), body=body)


def timeout_error() -> TransportError:
    return TransportError("timeout")
