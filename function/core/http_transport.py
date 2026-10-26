"""Adaptador real del puerto `HttpTransport` con `requests`. No registra cabeceras ni cuerpos."""

from __future__ import annotations

from collections.abc import Mapping
from typing import Any

import requests

from .ports import HttpResponse, TransportError


class RequestsTransport:
    def __init__(self, session: Any = None) -> None:
        self._session = session or requests.Session()

    def request(
        self,
        method: str,
        url: str,
        *,
        headers: Mapping[str, str] | None = None,
        json: Any = None,
        timeout: float = 10.0,
    ) -> HttpResponse:
        try:
            response = self._session.request(
                method, url, headers=dict(headers or {}), json=json, timeout=timeout
            )
        except requests.RequestException as exc:
            # Solo el tipo de error: el mensaje de requests puede incluir la URL completa.
            raise TransportError(type(exc).__name__) from None
        try:
            body: Any = response.json()
        except ValueError:
            body = response.text or None
        return HttpResponse(status=response.status_code, headers=dict(response.headers), body=body)
