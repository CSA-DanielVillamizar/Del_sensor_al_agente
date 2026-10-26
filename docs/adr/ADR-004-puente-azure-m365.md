# ADR-004 — Puente de Azure a Microsoft 365: IoT Hub → Function → Graph → flujo HTTP (DEC-02)

| Campo | Valor |
| --- | --- |
| Estado | Aceptado ("aprobado fase 2" de Daniel, 2026-10-26) |
| Fecha | 2026-10-09 |
| Decisión relacionada | DEC-02 en `specs/01-especificacion.md` §7; depende de DEC-05 ([ADR-003](ADR-003-disparo-del-agente.md)) y DEC-04 ([ADR-006](ADR-006-deduplicacion.md)) |
| Historias | HU-02 (CA-02.2), HU-05 (CA-05.2, CA-05.3, CA-05.5), HU-06 (CA-06.1, CA-06.3), HU-12 (CA-12.1), RNF-01, RNF-04 |
| Responsables | arquitecto-cloud; revisión: revisor-seguridad, arquitecto-m365 |

## Contexto

- DEC-02 fija que la lista de SharePoint `Eventos de seguridad` es el **registro de auditoría** y que la Function escribe en ella con Microsoft Graph. ADR-003 añade que, **después** de crear el elemento, la Function llama a un flujo del agente con disparador HTTP que ejecuta *Ejecutar agente* (p90 del tramo 2 = 10,5 s en el spike).
- El tramo 1 (dispositivo → elemento creado) tiene p90 ≤ 10 s (CA-05.5). El total debe quedar en p90 ≤ 30 s y nunca > 60 s (OBJ-2).
- La Function lee los mensajes del **endpoint integrado compatible con Event Hubs** de IoT Hub ([Read device-to-cloud messages from the built-in endpoint](https://learn.microsoft.com/azure/iot-hub/iot-hub-devguide-messages-read-builtin)). La entrega es "al menos una vez": al reanudar desde un *checkpoint* un evento puede procesarse más de una vez y Learn pide diseñar el consumidor como idempotente ([Reliability in Azure Event Hubs](https://learn.microsoft.com/azure/reliability/reliability-event-hubs#resilience-to-transient-faults)).
- IoT Hub reparte los mensajes por particiones según el `deviceId` de origen ([Create and read IoT Hub messages](https://learn.microsoft.com/azure/iot-hub/iot-hub-devguide-messages-construct)), así que los mensajes de una misma identidad de dispositivo llegan en orden a la misma partición.
- El disparador de Event Hubs admite políticas de reintento (*fixed delay* o *exponential backoff*), y el *checkpoint* no se escribe hasta que termina la política, lo que detiene la partición mientras tanto ([Azure Functions error handling and retries](https://learn.microsoft.com/azure/azure-functions/functions-bindings-error-pages#retry-policies)). El reintento es "de mejor esfuerzo" y no sustituye el manejo de errores en el código ([Resilient Event Hubs and Functions design](https://learn.microsoft.com/azure/architecture/serverless/event-hubs-functions/resilient-design#error-handling-and-retries)).
- Graph y SharePoint responden 429 o 503 con `Retry-After` cuando limitan; reintentar antes de ese plazo empeora la limitación ([Microsoft Graph throttling guidance](https://learn.microsoft.com/graph/throttling#best-practices-to-handle-throttling), [Avoid getting throttled in SharePoint Online](https://learn.microsoft.com/sharepoint/dev/general-development/how-to-avoid-getting-throttled-or-blocked-in-sharepoint-online#how-to-handle-throttling)).

## Decisión

### 1. Cadena y orden de escritura

Una sola función, `ingest_event`, disparada por el endpoint integrado de IoT Hub (un evento por invocación, grupo de consumidores dedicado `func`). Para cada mensaje, en este orden:

| Paso | Qué hace | Si falla |
| --- | --- | --- |
| 1. Validar | Valida el cuerpo contra `schemas/evento-dispositivo.schema.json` | No reintenta: registra `EventRejected` con `eventId` (si se puede leer) y el motivo, y termina sin excepción (CA-05.3) |
| 2. Reclamar ventana | En Table Storage, abre o encuentra la ventana de deduplicación de `deviceId`+`type` e inserta la fila del evento (clave = `eventId`). Detalle en [ADR-006](ADR-006-deduplicacion.md) | 412/409 → relee y repite (bucle acotado); error de red → excepción y reintento del runtime |
| 3. Límite por minuto | Solo si el evento **abre** un incidente: toma un cupo del minuto (ADR-006). Sin cupo → marca la ventana `discarded`, registra `IncidentDiscarded` y termina | Igual que el paso 2 |
| 4. Enriquecer | `zoneName`, `cameraId`, `site` y `SeveridadInicial` desde `data/zonas.json` (CA-05.1). Lógica pura, sin E/S | Zona desconocida → se trata como evento inválido (paso 1) |
| 5. Crear el elemento | `POST /sites/{site-id}/lists/{list-id}/items` con el contrato de columnas del plan, `Estado` = `Nuevo` y `EventId` = `eventId` del primer evento de la ventana ([Create item](https://learn.microsoft.com/graph/api/listitem-create)). Guarda el `itemId` en la ventana | Ver §2 |
| 6. Disparar al agente | `POST` al flujo HTTP con cuerpo `{"eventId": "..."}` y token de la identidad administrada (ADR-003, [ADR-007](ADR-007-identidad-y-permisos.md)). Marca `flowTriggered = true` en la ventana | Ver §2 |
| 7. Repeticiones | Si el evento **no** abre ventana: cuenta las filas de la ventana y hace `PATCH` de `Repeticiones` en el elemento ([Update listItem](https://learn.microsoft.com/graph/api/listitem-update)). No consume cupo del límite (CA-02.2) | Si la ventana aún no tiene `itemId` → excepción y reintento del runtime |

Razones del orden:
- **Table antes que Graph:** la ventana es el candado que evita dos incidentes para el mismo `deviceId`+`type` aunque haya reintentos o varias instancias.
- **Lista antes que flujo:** el registro de auditoría existe siempre antes de que el agente haga nada (DEC-02, ADR-003). El agente solo recibe el `eventId` y lee el incidente de la lista.
- **El mensaje al flujo es el `eventId` del primer evento de la ventana**, que es también el valor de la columna `EventId` del elemento.

### 2. Reintentos

| Llamada | Política en el código | Política del runtime |
| --- | --- | --- |
| Table Storage | SDK con sus reintentos por defecto; 409/412 se resuelven releyendo (máx. 5 vueltas) | — |
| Graph: crear y actualizar | Respeta `Retry-After` en 429/503; sin cabecera, retroceso exponencial con *jitter* (0,5 s, 1 s, 2 s). **Presupuesto total de 6 s** para no romper el p90 del tramo 1. 4xx distinto de 429 → no reintenta y registra `GraphRejected` | Si se agota el presupuesto, lanza excepción |
| Flujo HTTP | 3 intentos (1 s, 2 s, 4 s) en 429, 5xx y *timeout* (10 s). 401/403 → no reintenta, registra `AgentTriggerAuthFailed` (problema de configuración, R-13) | Lanza excepción tras el tercer intento |
| Runtime de Functions | — | `exponential_backoff`, `max_retry_count` = 3, mínimo 5 s, máximo 30 s ([retry policies](https://learn.microsoft.com/azure/azure-functions/functions-bindings-error-pages#retry-policies)). Tras agotarlo se registra `EventFailed` y el evento queda visible en la consulta de errores; no hay cola de mensajes fallidos en esta demo |

Un incidente cuyo flujo no se pudo disparar queda en la lista con `Estado` = `Nuevo`. El preflight lo detecta y `demo/retrigger` vuelve a llamar al flujo con su `eventId`.

### 3. Idempotencia por `eventId`

| Situación | Qué evita la duplicación |
| --- | --- |
| IoT Hub o el runtime entregan otra vez el **mismo** evento | La fila del evento en Table (clave `eventId`) ya existe → 409 → no se cuenta otra repetición. Los pasos 5 y 6 consultan `itemId` y `flowTriggered` en la ventana antes de actuar |
| La Function cae entre crear el elemento y guardar `itemId` | La columna `EventId` se crea con `enforceUniqueValues` e índice ([columnDefinition](https://learn.microsoft.com/graph/api/resources/columndefinition)). Si el `POST` choca con la unicidad, la Function busca el elemento por `EventId` y continúa. El código de error exacto que devuelve Graph en ese choque no está documentado: **riesgo R-14** |
| El flujo recibe dos veces el mismo `eventId` | `PublicarIncidente` no vuelve a publicar un incidente que ya no esté en `Nuevo` (ADR-003, DEC-01). El agente sí puede ejecutarse dos veces y consumir créditos; se acepta porque solo ocurre con un fallo intermedio |
| Ráfaga de 20 eventos del mismo `deviceId`+`type` | Un solo incidente; `Repeticiones` = número de filas de la ventana, que es idempotente por construcción (CA-02.2) |

### 4. Correlación y medición

Cada paso escribe una línea de registro estructurada con `eventId`, `incidentEventId`, `deviceId`, `type`, `step`, `outcome` y tiempos en UTC. El tramo 1 se calcula como `graphCreatedUtc − enqueuedTimeUtc`; `enqueuedTimeUtc` lo aporta el disparador (`EventHubEvent.enqueued_time`, [EventHubEvent](https://learn.microsoft.com/python/api/azure-functions/azure.functions.eventhubevent)). Por eso la función usa el tipo `func.EventHubEvent` y **no** los *SDK type bindings*, que no exponen `enqueued_time` ([IoT Hub trigger, Python](https://learn.microsoft.com/azure/azure-functions/functions-bindings-event-iot-trigger#example)).

## Alternativas consideradas

| Alternativa | Por qué no |
| --- | --- |
| Llamar al flujo **antes** de escribir en la lista, o en paralelo | El agente podría actuar sobre un incidente que no está en el registro de auditoría; rompe DEC-02 |
| Que el flujo cree el elemento (la Function solo llama al flujo) | La Function dejaría de ser el único escritor; los datos del incidente viajarían en el cuerpo HTTP y la auditoría dependería del flujo |
| Cola intermedia (Service Bus o Storage Queue) entre la Function y Graph | Más piezas y más latencia para una demo de un solo dispositivo. Se documenta como mejora de producción en `docs/gobernanza.md` |
| Reintentar Graph sin límite dentro de la Function | Bloquea la partición y rompe el presupuesto de 10 s del tramo 1 |
| Deduplicar en la lista de SharePoint (buscar por `deviceId`+`type` antes de crear) | Una consulta más por evento, sin concurrencia optimista; ver ADR-006 |

## Consecuencias

- **A favor:** el orden deja siempre un registro de auditoría antes del agente; todo reintento es seguro; un solo identificador (`eventId`) une IoT Hub, Table, la lista, el flujo y Application Insights.
- **En contra:** la Function hace hasta 5 llamadas por evento nuevo (2–3 a Table, 1 a Graph, 1 al flujo). Con los tiempos habituales cabe holgadamente en 10 s, pero el preflight mide el tramo 1 en cada ejecución.
- **Riesgos:** R-13 (token de la identidad administrada para el flujo, ADR-007) y R-14 (comportamiento de Graph ante `enforceUniqueValues`). Prueba de R-14: crear dos veces un elemento con el mismo `EventId` en la lista de pruebas y registrar el código y el cuerpo de error; si Graph no rechaza el duplicado, la Function consulta por `EventId` (columna indexada) antes de cada creación, a costa de unos cientos de milisegundos.
- **Fuera de alcance:** cola de mensajes fallidos, reprocesamiento automático y alertas; quedan en la lista de producción de `docs/gobernanza.md`.
