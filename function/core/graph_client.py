"""Cliente mínimo de Microsoft Graph para la lista de incidentes (ADR-004 §2, CA-06.1).

- Crear: `POST /sites/{site-id}/lists/{list-id}/items` (https://learn.microsoft.com/graph/api/listitem-create).
- Actualizar: `PATCH .../items/{item-id}/fields` (https://learn.microsoft.com/graph/api/listitem-update).
- 429/503 con `Retry-After`: se espera ese plazo; sin cabecera, retroceso 0,5 s, 1 s, 2 s con
  jitter (https://learn.microsoft.com/graph/throttling#best-practices-to-handle-throttling).
  Presupuesto total de espera: 6 s, para no romper el p90 del tramo 1.
- 4xx distinto de 429: no se reintenta (`GraphRejected`).
- Choque con la unicidad de `EventId` (R-14, código no documentado): se busca el elemento por
  `EventId` y se continúa.

El token se pide a la credencial en cada llamada (la credencial de azure-identity lo guarda en
caché) y nunca se registra ni se incluye en un error.
"""

from __future__ import annotations

import random
import re
from collections.abc import Callable, Mapping
from dataclasses import dataclass
from typing import Any
from urllib.parse import quote

from .ports import Clock, Credential, HttpResponse, HttpTransport, TransportError

GRAPH_SCOPE = "https://graph.microsoft.com/.default"
GRAPH_BASE = "https://graph.microsoft.com/v1.0"
RETRYABLE = frozenset({429, 500, 502, 503, 504})
BACKOFF = (0.5, 1.0, 2.0)
REQUEST_TIMEOUT = 5.0
_UUID = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$")


class GraphRejected(Exception):
    """Graph rechazó la petición sin posibilidad de reintento (p. ej. 403 fuera del sitio de la demo)."""

    def __init__(self, status: int, code: str | None) -> None:
        super().__init__(f"Graph respondió {status} ({code or 'sin código'})")
        self.status = status
        self.code = code


class GraphRetryBudgetExceeded(Exception):
    """Se agotaron los reintentos o el presupuesto de 6 s; entra el reintento del runtime."""


@dataclass(frozen=True)
class CreatedItem:
    item_id: str
    existing: bool  # True si ya existía por la unicidad de EventId (reentrega tras una caída)


def _error_code(response: HttpResponse) -> str | None:
    body = response.body
    if isinstance(body, Mapping) and isinstance(body.get("error"), Mapping):
        code = body["error"].get("code")
        return code if isinstance(code, str) else None
    return None


def _is_unique_conflict(response: HttpResponse) -> bool:
    if response.status == 409:
        return True
    if response.status == 400 and isinstance(response.body, Mapping):
        error = response.body.get("error") or {}
        text = f"{error.get('code', '')} {error.get('message', '')}".lower()
        return "unique" in text or "duplicate" in text
    return False


def _retry_after(response: HttpResponse) -> float | None:
    value = response.header("Retry-After")
    if value is None:
        return None
    try:
        return max(0.0, float(value))
    except ValueError:
        return None


class GraphClient:
    def __init__(
        self,
        transport: HttpTransport,
        credential: Credential,
        clock: Clock,
        *,
        site_id: str,
        list_id: str,
        budget_seconds: float = 6.0,
        base_url: str = GRAPH_BASE,
        jitter: Callable[[], float] = random.random,
    ) -> None:
        self._transport = transport
        self._credential = credential
        self._clock = clock
        self._items_url = f"{base_url}/sites/{site_id}/lists/{list_id}/items"
        self._budget = budget_seconds
        self._jitter = jitter

    def create_item(self, fields: Mapping[str, Any]) -> CreatedItem:
        response = self._send("POST", self._items_url, {"fields": dict(fields)}, allow_conflict=True)
        if _is_unique_conflict(response):
            existing = self.find_item_by_event_id(str(fields.get("EventId", "")))
            if existing is None:
                raise GraphRejected(response.status, _error_code(response))
            return CreatedItem(item_id=existing, existing=True)
        return CreatedItem(item_id=str(response.body["id"]), existing=False)

    def update_fields(self, item_id: str, fields: Mapping[str, Any]) -> None:
        self._send("PATCH", f"{self._items_url}/{quote(item_id, safe='')}/fields", dict(fields))

    def find_item_by_event_id(self, event_id: str) -> str | None:
        if not _UUID.match(event_id):
            raise ValueError("eventId con formato no válido")
        odata_filter = quote(f"fields/EventId eq '{event_id}'")
        url = f"{self._items_url}?$filter={odata_filter}&$select=id"
        response = self._send("GET", url, None)
        values = response.body.get("value", []) if isinstance(response.body, Mapping) else []
        return str(values[0]["id"]) if values else None

    def _send(self, method: str, url: str, body: Any, *, allow_conflict: bool = False) -> HttpResponse:
        start = self._clock.monotonic()
        retries = 0
        while True:
            headers = {
                "Authorization": f"Bearer {self._credential.get_token(GRAPH_SCOPE).token}",
                "Content-Type": "application/json",
            }
            wait: float | None = None
            try:
                response = self._transport.request(
                    method, url, headers=headers, json=body, timeout=REQUEST_TIMEOUT
                )
            except TransportError:
                response = None
            if response is not None:
                if 200 <= response.status < 300:
                    return response
                if allow_conflict and _is_unique_conflict(response):
                    return response
                if response.status not in RETRYABLE:
                    raise GraphRejected(response.status, _error_code(response))
                wait = _retry_after(response)

            if retries >= len(BACKOFF):
                raise GraphRetryBudgetExceeded(f"Graph: {retries} reintentos agotados")
            if wait is None:
                base = BACKOFF[retries]
                wait = base * (1 + 0.25 * self._jitter())
            elapsed = self._clock.monotonic() - start
            if elapsed + wait > self._budget:
                raise GraphRetryBudgetExceeded(
                    f"Graph: la espera superaría el presupuesto de {self._budget} s"
                )
            self._clock.sleep(wait)
            retries += 1
