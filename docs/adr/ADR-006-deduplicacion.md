# ADR-006 — Ventana de deduplicación y límite por minuto en Table Storage (DEC-04)

| Campo | Valor |
| --- | --- |
| Estado | Propuesto (Fase 2, pendiente de "aprobado fase 2") |
| Fecha | 2026-10-09 |
| Decisión relacionada | DEC-04 en `specs/01-especificacion.md` §7 |
| Historias | HU-02 (CA-02.2), HU-05 (CA-05.2, CA-05.4), HU-12 (CA-12.1), R-07 |
| Responsables | arquitecto-cloud; revisión: revisor-seguridad |

## Contexto

- CA-05.2: eventos con el mismo `deviceId` y `type` dentro de una ventana **fija de 60 s contada desde el primer evento** producen un solo incidente con `Repeticiones` acumuladas; un evento posterior abre otro incidente.
- CA-12.1: como máximo N incidentes **creados** por minuto (por defecto 10), registrando lo descartado. Las actualizaciones de `Repeticiones` no cuentan (CA-02.2).
- El estado no puede vivir en memoria: Flex Consumption puede tener más de una instancia (*always ready* + bajo demanda, ADR-005), y el runtime reintenta y reentrega eventos (ADR-004).
- Table Storage ofrece concurrencia optimista con `ETag` e `If-Match`: si el `ETag` cambió, la actualización falla con 412 y hay que releer y repetir ([Update Entity](https://learn.microsoft.com/rest/api/storageservices/update-entity2#remarks), [Merge Entity](https://learn.microsoft.com/rest/api/storageservices/merge-entity#remarks)). Insertar una entidad que ya existe falla con 409 `EntityAlreadyExists` ([Table Storage error codes](https://learn.microsoft.com/rest/api/storageservices/table-service-error-codes)).
- IoT Hub reparte los mensajes por particiones según el `deviceId` de origen ([Create and read IoT Hub messages](https://learn.microsoft.com/azure/iot-hub/iot-hub-devguide-messages-construct)), así que en la práctica los eventos de una identidad se procesan en serie; la concurrencia real aparece con reintentos, reequilibrio de particiones y reentregas.
- El rol mínimo para leer y escribir entidades es *Storage Table Data Contributor* ([Grant permissions to an identity](https://learn.microsoft.com/azure/azure-functions/manage-connections#grant-permissions-to-an-identity)).

## Decisión

La ventana y el límite viven en **Table Storage, en la misma cuenta del host**, con tablas propias y acceso por la identidad administrada (sin claves). El reloj de referencia es `enqueuedTimeUtc` de IoT Hub, no el `timestamp` del dispositivo, para que un reloj desajustado en el simulador o en la Raspberry Pi no abra ni cierre ventanas.

### Modelo de datos

| Tabla | PartitionKey | RowKey | Propiedades | Uso |
| --- | --- | --- | --- | --- |
| `dedup` | `{deviceId}\|{type}` | `current` | `windowId` (= `eventId` del primer evento), `windowStartUtc`, `state` (`open` / `discarded`), `itemId`, `flowTriggered` | Cabecera de la ventana vigente, protegida con `ETag` |
| `dedup` | `w\|{windowId}` | `{eventId}` | `enqueuedTimeUtc` | Una fila por evento; su número es `Repeticiones` |
| `ratelimit` | `minute` | `yyyyMMddHHmm` (UTC de procesamiento) | `count` | Cupo de incidentes creados por minuto, protegido con `ETag` |

### Algoritmo (lógica pura en `function/core/dedup.py` y `function/core/ratelimit.py`, E/S detrás de una interfaz)

1. Leer la cabecera `({deviceId}|{type}, current)`.
2. Si no existe → insertar una cabecera nueva con `windowId = eventId`. Si responde 409, otra ejecución ganó: volver a 1.
3. Si existe y `enqueuedTimeUtc − windowStartUtc ≥ 60 s` → reemplazarla por una ventana nueva con `If-Match: <ETag>`. Si responde 412, volver a 1.
4. Si existe y está dentro de los 60 s → el evento es una **repetición** de `windowId`.
5. Insertar la fila `(w|{windowId}, {eventId})`. Si responde 409, es una reentrega del mismo evento: no se cuenta otra vez, pero se completan los pasos pendientes de la ventana (idempotencia, ADR-004).
6. Si el evento **abrió** la ventana: incrementar `ratelimit(minute, yyyyMMddHHmm)` con `If-Match` (insertar si no existe). Si `count` ya llegó a `MAX_INCIDENTS_PER_MINUTE` (app setting, por defecto 10), marcar la cabecera `state = discarded`, registrar `IncidentDiscarded` con `eventId` y terminar. Las repeticiones de una ventana descartada también se descartan y se registran.
7. Si es una repetición de una ventana `open`: `Repeticiones` = número de filas de `w|{windowId}` (consulta de una sola partición, a lo sumo decenas de filas).

Cada bucle de relectura tiene un máximo de 5 vueltas; si se agota, la ejecución lanza una excepción y entra la política de reintento del runtime (ADR-004).

### Reinicio

`demo/reset` borra todas las entidades de `dedup` y `ratelimit` con la identidad de Daniel (rol *Storage Table Data Contributor* sobre la cuenta, asignado por Bicep con el parámetro `operatorPrincipalId`), para que el primer evento de la demo siempre abra un incidente.

## Alternativas consideradas

| Alternativa | Por qué no |
| --- | --- |
| Memoria de la instancia | Se pierde al escalar, reiniciar o con *always ready* + bajo demanda (R-07) |
| Consultar la lista de SharePoint por `deviceId`+`type` antes de crear | Sin concurrencia optimista entre la consulta y la creación; suma latencia de Graph a cada evento y gasta cuota de limitación de SharePoint |
| Azure Cache for Redis | Recurso con costo fijo que rompe el presupuesto para una demo |
| Cosmos DB (sin servidor) | Funcionaría con `ETag`, pero suma un recurso y un modelo de permisos propio; Table Storage ya está en la cuenta del host |
| Durable Entities | Más piezas y más latencia para un contador; el patrón de reintento de Durable no aporta aquí |
| Ventana deslizante (cada repetición extiende 60 s) | Contradice CA-05.2 ("fija, contada desde el primer evento") |
| Contador `Repeticiones` incrementado en la cabecera | No es idempotente ante reentregas; contar filas sí lo es |

## Consecuencias

- **A favor:** costo prácticamente nulo (operaciones de Table a USD 0,00036 por 10 000 en `eastus2`, [precios de Azure Storage](https://azure.microsoft.com/pricing/details/storage/tables/)); correcto con varias instancias y con reentregas; probado con un repositorio en memoria sin Azure (CA-05.4).
- **En contra:** 2 a 4 operaciones de Table por evento, decenas de milisegundos que entran en el presupuesto del tramo 1. El límite por minuto usa ventanas fijas de reloj: en el cambio de minuto pueden crearse hasta 2N incidentes en 60 s. Para la demo (N = 10) se acepta y se documenta.
- **Datos:** las entidades solo guardan `deviceId`, `type`, `eventId` y horas; ningún dato personal (Art. 4).
