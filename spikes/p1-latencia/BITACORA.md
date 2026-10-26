# SPK-01 — Bitácora de cambios en el tenant de la demo en vivo

Registro de cada cambio de configuración hecho para correr el spike en el tenant de la demo en vivo (ADR-002), con su motivo. La guía y el README describen la configuración recomendada; esta bitácora explica por qué el entorno real se apartó de ella.

Autorización: Daniel, 2026-10-09 ("estás autorizado para hacer los cambios que se necesiten, pero documenta el porqué").

## Cambios

| # | Fecha (UTC) | Cambio | Hecho por | Por qué | ¿Se revierte? |
| --- | --- | --- | --- | --- | --- |
| 1 | 2026-10-09 | Lista `SpikeEventosA` (columna `EventId`) y lista `SpikeLatencia` (`EventId`, `Opcion`, `T1Utc`, `T2Utc`) en el sitio de la demo | `agente-dsa` (API REST de SharePoint) | Origen de la opción A y sumidero de la medición | Sí, al cerrar DEC-05 (pasos 17–18 del README) |
| 2 | 2026-10-09 | Canal estándar `Pruebas spike` en el equipo `DSA-Demo` | Daniel (Graph, sesión de la CLI) | Que los mensajes del spike no ensucien `Centro de operaciones` | Sí, al terminar el spike |
| 3 | 2026-10-09 | Prueba de Copilot Studio para `agente-dsa` (registro por "Iniciar prueba gratuita") | Daniel completó el formulario | Business Premium solo incluye Copilot Studio para Microsoft 365 (orquestación clásica). Sin la prueba, `agente-dsa` no tenía IA generativa, disparadores ni flujos del agente. **Desviación:** lo recomendado es la licencia de usuario de Copilot Studio (§8.1) | No antes del evento; vence con la prueba |
| 4 | 2026-10-09 | Agente `Spike Latencia` creado en **español** | `agente-dsa` | Primer intento; el idioma lo toma del entorno | **Descartado:** los disparadores de evento solo admiten agentes en `en-US`. Daniel debe borrarlo |
| 5 | 2026-10-09 | Agente `Spike Latencia EN` en **inglés (en-US)**, standard harness, orquestación generativa activada, instrucciones y herramienta `RegistrarReaccion` | `agente-dsa` | Learn: los disparadores de evento solo admiten `en-US` ([Language support](https://learn.microsoft.com/microsoft-copilot-studio/authoring-language-support)) | Sí, al cerrar DEC-05 |
| 6 | 2026-10-09 | Aceptación de los términos de Power Automate al agregar el disparador de SharePoint (sin correos promocionales) | `agente-dsa` | Requisito del portal para crear el disparador | No aplica |
| 7 | 2026-10-09 | Disparador SharePoint *Cuando se crea un elemento* sobre `SpikeEventosA` (opción A) | `agente-dsa` | Medir la opción A | Sí |
| 8 | 2026-10-09 | Agente `Spike Latencia EN` **publicado** | `agente-dsa` | Los disparadores solo reaccionan con el agente publicado | Se borra con el agente |
| 9 | 2026-10-09 | Flujo del agente "Sin título" con disparador HTTP (*Cualquier usuario de mi inquilino*, autenticación Entra, sin firma en la URL) → *Ejecutar agente* | `agente-dsa` | Medir la opción C sin disparador por sondeo. Se eligió autenticación Entra en vez de URL con firma: no hay secreto que proteger | Sí, salvo que el Plan lo reutilice |
| 10 | 2026-10-09 | Auditoría de Dataverse y registro de acceso en `DSA-Demo` (180 días) | Daniel | Mitigación de ADR-002: el entorno predeterminado no admite grupo de seguridad | No |
| 11 | 2026-10-09 | Borrado del agente en español `Spike Latencia` (cambio 4) | Daniel | Limpieza del intento descartado | No aplica |
| 12 | 2026-10-09 | Disparador SharePoint *Cuando se crea un elemento* eliminado del agente `Spike Latencia EN` (cambio 7), en todas sus versiones | `agente-dsa` | Opción A descartada (ADR-003); limpieza aprobada por Daniel | No aplica |
| 13 | 2026-10-09 | Lista `SpikeEventosA` eliminada (cambio 1, parte de la opción A) | Daniel | Opción A descartada (ADR-003) | No aplica |
| 14 | 2026-10-26 | Flujo HTTP del spike reutilizado como `DisparoAgente`: ahora ejecuta el Agente de Operaciones, acepta solo a la identidad de la Function y a la cuenta del operador, y recibe `{eventId}` | `agente-dsa` | El buscador de acciones del diseñador no mostraba *Ejecutar agente* del conector de Copilot Studio; reutilizar el flujo evitó el bloqueo. **Desviación del plan §15** (decía rehacerlo): pendiente agregarlo a la solución `DelSensorAlAgente` | No |

## Hallazgos que cambian la especificación

1. **Idioma del agente:** los disparadores de evento exigen idioma principal `en-US`, que no se puede cambiar después de crear el agente. El agente de la demo se crea en inglés y sus instrucciones ordenan responder en español.
2. **Licencia de la cuenta de servicio:** Business Premium no basta para un agente con orquestación generativa; hace falta Copilot Studio (licencia de usuario o prueba).
3. **Token del disparador HTTP:** con *Cualquier usuario de mi inquilino*, la llamada necesita un token de Entra con audiencia `https://service.flow.microsoft.com/`. Con `https://api.powerplatform.com` el servicio respondió HTTP 500.
4. **Latencia de la opción A:** el disparador de SharePoint tardó unos 33 s en entregar el evento al agente (Activity del agente); el agente decidió en unos 2 s y la herramienta tardó 3,6 s.
5. **Latencia de la opción C:** con el flujo HTTP → *Ejecutar agente*, 20 de 20 eventos completaron el tramo 2: p50 7,1 s, p90 10,5 s, máximo 14,1 s. La reacción del agente no pasó de 5,1 s; la variación viene de la publicación en Teams. Decisión propuesta en [ADR-003](../../docs/adr/ADR-003-disparo-del-agente.md).

## Pendiente de limpieza

- Se conservan hasta que el Plan decida: agente `Spike Latencia EN`, flujo HTTP de la opción C, lista `SpikeLatencia` y canal `Pruebas spike` (este último para los ensayos).
