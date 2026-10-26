"""Paso 6 de ADR-004: disparar el flujo `DisparoAgente` con el token de la identidad (ADR-003, ADR-007).

- Alcance `https://service.flow.microsoft.com//.default`: la audiencia que exige el disparador
  termina en barra, y entonces `.default` lleva doble barra
  (https://learn.microsoft.com/entra/identity-platform/scopes-oidc#trailing-slash-and-default,
  https://learn.microsoft.com/power-automate/oauth-authentication).
- Cuerpo: solo `{"eventId": ...}` (plan §4.5).
- 3 intentos en total, con esperas de 1 s y 2 s, ante 429, 5xx o tiempo agotado (10 s).
- 401/403: no se reintenta; es un problema de configuración (R-13) → `AgentTriggerAuthFailed`.
- La URL debe ser https y **no** puede llevar firma SAS (`sig=`): el disparador se protege con
  Entra ID, no con un secreto en la URL (ADR-007). En registros solo aparece el host.

El token nunca se registra ni se incluye en un error.
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from urllib.parse import parse_qs, urlsplit

from .ports import Clock, Credential, HttpTransport, TransportError

FLOW_SCOPE = "https://service.flow.microsoft.com//.default"
MAX_ATTEMPTS = 3
DELAYS = (1.0, 2.0)
TIMEOUT = 10.0
_UUID = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$")


class FlowAuthRejected(Exception):
    """El flujo rechazó la identidad (401/403)."""

    def __init__(self, status: int) -> None:
        super().__init__(f"El flujo rechazó la identidad: HTTP {status}")
        self.status = status


class FlowTriggerRejected(Exception):
    """El flujo respondió un 4xx no transitorio."""

    def __init__(self, status: int) -> None:
        super().__init__(f"El flujo rechazó la petición: HTTP {status}")
        self.status = status


class FlowTriggerFailed(Exception):
    """Tres intentos sin éxito; entra el reintento del runtime."""


@dataclass(frozen=True)
class TriggerResult:
    status: int
    attempts: int


class FlowTrigger:
    def __init__(
        self, transport: HttpTransport, credential: Credential, clock: Clock, *, flow_url: str
    ) -> None:
        parts = urlsplit(flow_url)
        if parts.scheme != "https" or not parts.hostname:
            raise ValueError("La URL del flujo debe ser https")
        if "sig" in {k.lower() for k in parse_qs(parts.query)}:
            raise ValueError(
                "La URL del flujo no puede llevar firma SAS (sig); usa autenticación de Entra ID"
            )
        self._transport = transport
        self._credential = credential
        self._clock = clock
        self._url = flow_url
        self.safe_target = parts.hostname

    def trigger(self, event_id: str) -> TriggerResult:
        if not _UUID.match(event_id):
            raise ValueError("eventId con formato no válido")
        last = "sin respuesta"
        for attempt in range(1, MAX_ATTEMPTS + 1):
            headers = {
                "Authorization": f"Bearer {self._credential.get_token(FLOW_SCOPE).token}",
                "Content-Type": "application/json",
            }
            try:
                response = self._transport.request(
                    "POST", self._url, headers=headers, json={"eventId": event_id}, timeout=TIMEOUT
                )
            except TransportError:
                last = "tiempo agotado o error de red"
            else:
                if 200 <= response.status < 300:
                    return TriggerResult(status=response.status, attempts=attempt)
                if response.status in (401, 403):
                    raise FlowAuthRejected(response.status)
                if response.status != 429 and response.status < 500:
                    raise FlowTriggerRejected(response.status)
                last = f"HTTP {response.status}"
            if attempt < MAX_ATTEMPTS:
                self._clock.sleep(DELAYS[attempt - 1])
        raise FlowTriggerFailed(f"El flujo no respondió tras {MAX_ATTEMPTS} intentos ({last})")
