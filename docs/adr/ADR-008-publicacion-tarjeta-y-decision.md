# ADR-008 — Publicación de la tarjeta y captura de la decisión (DEC-01)

| Campo | Valor |
| --- | --- |
| Estado | Aceptado ("aprobado fase 2" de Daniel, 2026-10-26) |
| Fecha | 2026-10-09 |
| Decisión relacionada | DEC-01 en `specs/01-especificacion.md` §7 (dirección aprobada en la Compuerta 1) |
| Historias | HU-09 (CA-09.1–CA-09.5), HU-10 (CA-10.1–CA-10.6), HU-08 (CA-08.6) |
| Depende de | [ADR-003](ADR-003-disparo-del-agente.md) (flujo HTTP → *Ejecutar agente* con solo el `eventId`) |
| Responsables | arquitecto-m365; revisión: revisor-seguridad |

## Contexto

El agente propone y la persona decide (Art. 1). La decisión del supervisor puede tardar minutos, pero una herramienta del agente tiene que responder rápido:

- Un flujo del agente usado como herramienta debe tener *When an agent calls the flow* y *Respond to the agent*, con **Asynchronous response = Off**, y responder **dentro del límite de 100 segundos**. Las acciones que tardan más pueden ir **después** de *Respond to the agent* y siguen ejecutándose hasta el límite de duración de 30 días ([Create an agent flow as a tool](https://learn.microsoft.com/microsoft-copilot-studio/advanced-flow-create); [Add an agent flow as a tool](https://learn.microsoft.com/microsoft-copilot-studio/flow-agent)).
- La duración máxima de una ejecución de flujo es 30 días; una solicitud saliente asíncrona (por ejemplo, una espera de webhook) tiene tiempo de espera configurable hasta 30 días ([Limits and configuration](https://learn.microsoft.com/power-automate/limits-and-config#timeout)).
- El modo *express* no admite acciones de tipo *webhook* ni *delay* ([Express mode — limitations](https://learn.microsoft.com/microsoft-copilot-studio/agent-flow-express-mode#limitations)). La espera de la tarjeta es un webhook, así que `PublicarIncidente` **no** usa modo express.

## Decisión

`PublicarIncidente` es un **flujo del agente** (herramienta) con este orden:

1. **Entrada** (desde el agente): `eventId`, `severidadPropuesta`, `justificacionSeveridad`, `resumen`, `pasosProtocolo`, `protocoloAplicado`.
2. **Leer el elemento** de `Eventos de seguridad` por `EventId`. **Si `Estado` ≠ `Nuevo`**, responde al agente "ya publicado" y termina sin publicar (idempotencia ante reintentos de la Function, ADR-003 punto 4).
3. **Actualizar** el elemento: `Estado = Pendiente de decisión`, `SeveridadPropuesta`, `JustificacionSeveridad`, `ResumenAgente`, `ProtocoloAplicado`, `PublicacionSolicitadaUtc = utcNow()`. La regla de §5.0 (máximo un nivel) se comprueba aquí; si el agente propone un salto mayor, el flujo lo limita a un nivel y lo deja anotado en el historial de ejecución.
4. **Respond to the agent** (síncrono, Asynchronous response = Off). Hasta aquí: 2 llamadas a SharePoint, muy por debajo de 100 s.
5. **Post adaptive card and wait for a response** (conector Microsoft Teams), *Post as* = **Flow bot**, *Post in* = **Channel** (`Centro de operaciones`, canal estándar). El conector describe la acción como "publica una tarjeta en un chat o canal y espera la respuesta de cualquier usuario; pausa el flujo hasta que alguien responde" ([Teams connector — Post adaptive card and wait for a response](https://learn.microsoft.com/connectors/teams/#post-adaptive-card-and-wait-for-a-response)). Requiere que la app **Workflows** esté permitida en el Teams admin center, y no admite canales privados ([Teams connector — known issues](https://learn.microsoft.com/connectors/teams/#known-issues-and-limitations-with-actions)).
   - **Tiempo de espera:** en *Settings* de la acción, *Timeout* = `PT15M` (ISO 8601), tomado de la variable de entorno `dsa_TimeoutDecision` para poder acortarlo en pruebas.
   - **Update message / Should update card:** activado; la tarjeta original se reemplaza por la versión de solo lectura al responder ([Overview of adaptive cards — known issues](https://learn.microsoft.com/power-automate/overview-adaptive-cards#known-issues)).
6. **Rama de respuesta** (*run after* = correcto):
   1. Volver a leer el elemento. **Si `Estado` ≠ `Pendiente de decisión`**, no escribe nada y registra un `Compose` `SegundaRespuestaIgnorada` (CA-10.6).
   2. Si no, actualizar `Estado` (`Atendido` / `Escalado` / `Falsa alarma`), `Decision`, `DecididoPor`, `FechaDecision = utcNow()` y `Observacion`.
   3. `Escalar a autoridades` **solo se registra**: el flujo no tiene ninguna acción de correo, llamada ni mensaje fuera del canal (CA-10.3).
7. **Rama de vencimiento** (*Configure run after* = **has timed out**; [Cloud flow error reference — OperationTimedOut](https://learn.microsoft.com/power-automate/error-reference#timeout-and-throttling-errors)): si `Estado` sigue en `Pendiente de decisión`, lo pasa a `Sin respuesta` **sin** escribir `Decision` ni `DecididoPor`, y publica en el canal la tarjeta "Sin respuesta" con *Post card in a chat or channel* (CA-10.5).

### Quién respondió

El paso de *wait for a response* devuelve contenido dinámico de la respuesta; Learn indica que el identificador del usuario que envió la tarjeta está disponible en las acciones siguientes y que puede hacer falta el conector Office 365 Users para completar el perfil ([Overview of adaptive cards — known issues, punto 4](https://learn.microsoft.com/power-automate/overview-adaptive-cards#known-issues)). El flujo toma ese identificador, obtiene el UPN con *Get user profile (V2)* y lo escribe en `DecididoPor` (columna de persona). La acción elegida llega como `submitActionId` (el `title` de la acción, [Send proactive Teams messages](https://learn.microsoft.com/microsoft-copilot-studio/advanced-proactive-message#send-a-proactive-adaptive-card-and-wait-for-the-user-response)) y, además, en `data.decision` del `Action.Submit`, que es el valor que se usa (el título puede cambiar de texto; el dato no).

### Idempotencia (tres capas)

| Capa | Mecanismo | Respaldo |
| --- | --- | --- |
| Plataforma | Las tarjetas de *wait for a response* se envían una sola vez por tarjeta; el flujo continúa con la primera respuesta y las demás se ignoran | [Overview of adaptive cards — known issues, punto 3](https://learn.microsoft.com/power-automate/overview-adaptive-cards#known-issues) |
| Interfaz | La tarjeta se reemplaza por la versión de solo lectura (*Update message*), así nadie ve botones activos (CA-10.2) | Ídem, punto 5 |
| Datos | Condición sobre `Estado` antes de cada escritura (paso 2 y paso 6.1); una segunda invocación de `PublicarIncidente` para el mismo `eventId` no publica otra tarjeta | Diseño propio; se prueba en el tenant |

## Alternativas consideradas

| Alternativa | Por qué no |
| --- | --- |
| Publicar y esperar **antes** de *Respond to the agent* | Rompe el límite de 100 s en cuanto el supervisor tarda; la herramienta falla y el agente no termina. |
| *Asynchronous response = On* | La herramienta debe responder en tiempo real para usarse como tal; además el callback asíncrono solo se documenta para conversaciones, no para una ejecución sin usuario ([Asynchronous response](https://learn.microsoft.com/microsoft-copilot-studio/flow-asynchronous-response)). |
| *Post card* + disparador *When someone responds to an adaptive card* en otro flujo | Learn advierte el error "Something went wrong" al combinar ambos, y el disparador solo funciona en el entorno predeterminado ([Teams connector — known issues](https://learn.microsoft.com/connectors/teams/#known-issues-and-limitations-with-actions)). Rompería la configuración recomendada (Sandbox). |
| *Post as* = **Microsoft Copilot Studio agent** | Esa opción publica en el chat con el agente (1:1), no en un canal ([Send proactive Teams messages](https://learn.microsoft.com/microsoft-copilot-studio/advanced-proactive-message)); el escenario pide el canal del centro de operaciones. |
| Tarjeta enviada por el propio agente (nodo *Adaptive Card* en un tema) | El agente se dispara sin conversación de Teams (ADR-003); no hay canal ni usuario donde preguntar. |
| Aprobaciones de Power Automate | Otra experiencia (app Approvals) y otro formato; no muestra la propuesta del agente con el diseño de CA-09.2. |

## Consecuencias

- **A favor:** la herramienta responde en segundos (tramo 2 no espera a la persona); la espera de 15 min no cuenta para el límite de 100 s; la decisión queda en la lista con quién, qué y cuándo (Art. 1); no hay ninguna acción con efecto fuera del canal y la lista.
- **En contra:** cada incidente deja una ejecución de flujo abierta hasta 15 min; con el límite del conector de **25 operaciones no-GET del Flow bot por conexión cada 300 s** ([Teams connector — throttling](https://learn.microsoft.com/connectors/teams/#throttling-limits)), una ráfaga de más de ~12 incidentes en 5 min (tarjeta + aviso) podría estrangularse. La deduplicación y el límite de CA-12.1 lo hacen improbable en la demo.
- **Créditos:** las acciones del flujo después de *Respond to the agent* se cobran como acciones de flujo (ADR-001); la espera no consume acciones adicionales.
- **Tamaño:** una tarjeta debe pesar menos de ~28 KB ([Teams connector — message size](https://learn.microsoft.com/connectors/teams/#known-issues-and-limitations-with-actions)); la prueba de tarjetas lo comprueba.

## Riesgos (no verificables en Learn; se cierran con una prueba en el tenant)

| ID | Riesgo | Prueba que lo cierra | Plan B |
| --- | --- | --- | --- |
| R-M1 | Learn documenta el tiempo de espera configurable para solicitudes asíncronas en general, pero no lo confirma en la página de esta acción concreta | Tarea de verificación con `PT2M` en `Pruebas spike` | Rama paralela con *Delay* `PT15M` → marcar `Sin respuesta` → *Terminate*; la otra rama escribe la decisión con la misma condición sobre `Estado` |
| R-M2 | No se documenta qué ve el supervisor si pulsa la tarjeta **después** del vencimiento | Misma prueba | El aviso "Sin respuesta" dice que la tarjeta anterior venció y que no se registró ninguna decisión |
| R-M3 | No se documenta si *Update message* acepta JSON de tarjeta o solo texto | Misma prueba | Texto de solo lectura con la decisión, quién y hora COT; `cards/tarjeta-solo-lectura.json` queda como contrato para *Update an adaptive card in a chat or channel* si la acción devuelve el ID del mensaje |
| R-M4 | Los nombres exactos de los campos de salida (identificador del respondiente, `submitActionId`, datos del formulario) son dinámicos y no están en la referencia del conector | Se anotan en la guía al construir el flujo | — |
| R-M5 | La página general dice "una respuesta por tarjeta" y la de canales dice "una respuesta por respondiente y por tarjeta" | Dos cuentas pulsan la misma tarjeta antes del reemplazo | La condición sobre `Estado` (capa de datos) garantiza CA-10.6 aunque la plataforma deje pasar la segunda |
