"""Configuración de la Function desde app settings. Ningún valor es un secreto.

| Variable | Obligatoria | Uso |
| --- | --- | --- |
| `DSA_GRAPH_SITE_ID` | Sí | ID de Graph del sitio de la demo (`host,siteGuid,webGuid`) |
| `DSA_GRAPH_LIST_ID` | Sí | ID de la lista `Eventos de seguridad` |
| `DSA_FLOW_URL` | Sí | URL del disparador HTTP de `DisparoAgente` (Entra ID, sin `sig`) |
| `DSA_TABLE_ENDPOINT` | Sí (1) | `https://{cuenta}.table.core.windows.net` |
| `AZURE_CLIENT_ID` | Sí | Client ID de la identidad asignada por el usuario `id-dsa-func` |
| `DSA_MAX_INCIDENTS_PER_MINUTE` | No (10) | Límite de CA-12.1 |
| `DSA_TEST_DEVICE_ID` | No (`preflight-01`) | Identidad de IoT Hub que marca `EsPrueba` (ADR-007) |
| `DSA_CONTRACTS_DIR` | No | Ver `contracts.py` |

(1) Si falta, se usa `AzureWebJobsStorage__tableServiceUri` o `AzureWebJobsStorage__accountName`.

Los mensajes de error nombran las variables, nunca sus valores.
"""

from __future__ import annotations

import os
from collections.abc import Mapping
from dataclasses import dataclass

from .ratelimit import DEFAULT_MAX_PER_MINUTE


class ConfigurationError(Exception):
    """Falta una app setting o no es válida."""


@dataclass(frozen=True)
class Settings:
    site_id: str
    list_id: str
    flow_url: str
    table_endpoint: str
    client_id: str
    max_incidents_per_minute: int = DEFAULT_MAX_PER_MINUTE
    test_device_id: str = "preflight-01"
    window_seconds: int = 60


def _table_endpoint(env: Mapping[str, str]) -> str | None:
    if env.get("DSA_TABLE_ENDPOINT"):
        return env["DSA_TABLE_ENDPOINT"]
    if env.get("AzureWebJobsStorage__tableServiceUri"):
        return env["AzureWebJobsStorage__tableServiceUri"]
    if env.get("AzureWebJobsStorage__accountName"):
        return f"https://{env['AzureWebJobsStorage__accountName']}.table.core.windows.net"
    return None


def load_settings(env: Mapping[str, str] | None = None) -> Settings:
    env = os.environ if env is None else env
    values = {
        "DSA_GRAPH_SITE_ID": env.get("DSA_GRAPH_SITE_ID"),
        "DSA_GRAPH_LIST_ID": env.get("DSA_GRAPH_LIST_ID"),
        "DSA_FLOW_URL": env.get("DSA_FLOW_URL"),
        "DSA_TABLE_ENDPOINT": _table_endpoint(env),
        "AZURE_CLIENT_ID": env.get("AZURE_CLIENT_ID"),
    }
    missing = [name for name, value in values.items() if not value]
    if missing:
        raise ConfigurationError(f"Faltan app settings: {', '.join(missing)}")

    raw_limit = env.get("DSA_MAX_INCIDENTS_PER_MINUTE", str(DEFAULT_MAX_PER_MINUTE))
    try:
        limit = int(raw_limit)
    except ValueError:
        raise ConfigurationError("DSA_MAX_INCIDENTS_PER_MINUTE debe ser un entero") from None
    if limit < 1:
        raise ConfigurationError("DSA_MAX_INCIDENTS_PER_MINUTE debe ser al menos 1")

    return Settings(
        site_id=values["DSA_GRAPH_SITE_ID"],
        list_id=values["DSA_GRAPH_LIST_ID"],
        flow_url=values["DSA_FLOW_URL"],
        table_endpoint=values["DSA_TABLE_ENDPOINT"],
        client_id=values["AZURE_CLIENT_ID"],
        max_incidents_per_minute=limit,
        test_device_id=env.get("DSA_TEST_DEVICE_ID", "preflight-01"),
    )
