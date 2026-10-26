"""Azure Function `ingest_event` (modelo de programación v2). Solo orquesta: la lógica está en `core/`.

- Disparador: endpoint integrado de IoT Hub compatible con Event Hubs, un evento por invocación,
  grupo de consumidores `func`. La app setting `IoTHubConnection` es una referencia de Key Vault a
  la cadena de la política `func-reader` (solo ServiceConnect, ADR-005). Esa cadena incluye
  `EntityPath`, que reemplaza a `event_hub_name` en tiempo de ejecución
  (https://learn.microsoft.com/azure/azure-functions/functions-bindings-event-iot-trigger#decorators).
- Tipo `func.EventHubEvent` (no SDK type bindings) para tener `enqueued_time` (ADR-004 §4).
- Reintento del runtime: `exponential_backoff`, 3 reintentos, de 5 s a 30 s (ADR-004 §2,
  https://learn.microsoft.com/azure/azure-functions/functions-bindings-error-pages#retry-policies).
- Identidad: la asignada por el usuario `id-dsa-func` (`AZURE_CLIENT_ID`) para Table, Graph y el flujo.
"""

from __future__ import annotations

import functools
import logging

import azure.functions as func
from azure.identity import ManagedIdentityCredential
from core.clock import SystemClock
from core.contracts import load_contracts
from core.flow_trigger import FlowTrigger
from core.graph_client import GraphClient
from core.http_transport import RequestsTransport
from core.pipeline import IngestPipeline, PipelineSettings
from core.settings import load_settings
from core.table_repo import AzureTableStore
from core.telemetry import Telemetry

app = func.FunctionApp()


@functools.lru_cache(maxsize=1)
def _pipeline() -> IngestPipeline:
    """Arma la cadena una vez por instancia. No hace llamadas de red al construirse."""
    settings = load_settings()
    credential = ManagedIdentityCredential(client_id=settings.client_id)
    clock = SystemClock()
    transport = RequestsTransport()
    return IngestPipeline(
        contracts=load_contracts(),
        store=AzureTableStore.from_endpoint(settings.table_endpoint, credential),
        graph=GraphClient(transport, credential, clock, site_id=settings.site_id, list_id=settings.list_id),
        flow=FlowTrigger(transport, credential, clock, flow_url=settings.flow_url),
        clock=clock,
        telemetry=Telemetry(logging.getLogger("dsa.ingest")),
        settings=PipelineSettings(
            max_incidents_per_minute=settings.max_incidents_per_minute,
            window_seconds=settings.window_seconds,
            test_device_id=settings.test_device_id,
        ),
    )


@app.function_name(name="ingest_event")
@app.retry(
    strategy="exponential_backoff",
    max_retry_count="3",
    minimum_interval="00:00:05",
    maximum_interval="00:00:30",
)
@app.event_hub_message_trigger(
    arg_name="event",
    event_hub_name="iothub-builtin-endpoint",
    connection="IoTHubConnection",
    consumer_group="func",
    cardinality="one",
)
def ingest_event(event: func.EventHubEvent, context: func.Context) -> None:
    retry = getattr(context, "retry_context", None)
    _pipeline().run(
        event.get_body(),
        enqueued_utc=event.enqueued_time,
        # La pone IoT Hub, no el emisor: sirve para marcar EsPrueba (ADR-007).
        connection_device_id=(event.iothub_metadata or {}).get("connection-device-id"),
        retry_count=retry.retry_count if retry else 0,
        max_retry_count=retry.max_retry_count if retry else 0,
    )
