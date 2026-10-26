"""Puertos de E/S de la Function: tablas, transporte HTTP, credencial y reloj.

La lógica de `core` solo conoce estas interfaces; las implementaciones reales están en
`table_repo.py`, `http.py` y `clock.py`, y las pruebas usan dobles en memoria.
"""

from __future__ import annotations

from collections.abc import Mapping
from dataclasses import dataclass, field
from datetime import datetime
from typing import Any, Protocol


class EntityExists(Exception):
    """La entidad ya existe (Table Storage responde 409 EntityAlreadyExists)."""


class EtagMismatch(Exception):
    """El ETag no coincide o la entidad ya no existe (Table Storage responde 412)."""


class TransportError(Exception):
    """Fallo de red o tiempo de espera agotado; no hubo respuesta HTTP."""


class TableStore(Protocol):
    """Repositorio de tablas con concurrencia optimista (ADR-006)."""

    def get(self, table: str, pk: str, rk: str) -> tuple[dict[str, Any], str] | None:
        """Devuelve (entidad, etag) o None si no existe."""

    def insert(self, table: str, entity: dict[str, Any]) -> str:
        """Inserta y devuelve el ETag. Lanza EntityExists si ya existe."""

    def update(self, table: str, entity: dict[str, Any], etag: str, *, replace: bool = False) -> str:
        """Actualiza con If-Match y devuelve el ETag nuevo. Lanza EtagMismatch si cambió."""

    def count_partition(self, table: str, pk: str) -> int:
        """Número de entidades de una partición."""


@dataclass(frozen=True)
class HttpResponse:
    status: int
    headers: Mapping[str, str] = field(default_factory=dict)
    body: Any = None

    def header(self, name: str) -> str | None:
        lower = name.lower()
        for key, value in self.headers.items():
            if key.lower() == lower:
                return value
        return None


class HttpTransport(Protocol):
    def request(
        self,
        method: str,
        url: str,
        *,
        headers: Mapping[str, str] | None = None,
        json: Any = None,
        timeout: float = 10.0,
    ) -> HttpResponse:
        """Hace la petición. Lanza TransportError si no hay respuesta."""


class AccessToken(Protocol):
    token: str


class Credential(Protocol):
    """Misma forma que `azure.core.credentials.TokenCredential`."""

    def get_token(self, *scopes: str, **kwargs: Any) -> AccessToken: ...


class Clock(Protocol):
    def now(self) -> datetime:
        """Hora actual en UTC, con zona."""

    def monotonic(self) -> float: ...

    def sleep(self, seconds: float) -> None: ...
