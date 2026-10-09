# ADR-003 — Disparo del agente: flujo HTTP → *Ejecutar agente* (DEC-05)

| Campo | Valor |
| --- | --- |
| Estado | Propuesto; se acepta con el "aprobado fase 1" de Daniel |
| Fecha | 2026-10-09 |
| Decisión relacionada | DEC-05 en `specs/01-especificacion.md` §7 |
| Historias | HU-08 (CA-08.3, CA-08.6), OBJ-2, RNF-01 |
| Evidencia | Spike SPK-01 (`spikes/p1-latencia/`), bitácora en `spikes/p1-latencia/BITACORA.md` |
| Responsables | arquitecto-m365; revisión: revisor-seguridad |

## Contexto

El tramo 2 (incidente creado → mensaje en Teams) tiene un presupuesto de p90 ≤ 20 s (RNF-01, CA-08.6) para que el total cumpla OBJ-2 (p90 ≤ 30 s, nunca > 60 s). DEC-05 dejó tres mecanismos candidatos y pidió decidir con medición, no con suposiciones:

- **A.** Disparador de evento del agente sobre la lista de SharePoint (*Cuando se crea un elemento*).
- **B.** Disparador de evento sobre una tabla de Dataverse.
- **C.** Flujo con disparador HTTP que llama al agente con la acción *Ejecutar agente* del conector Microsoft Copilot Studio ([Call Copilot Studio agents from Power Automate](https://learn.microsoft.com/power-automate/call-copilot-studio-agent#call-a-standard-harness-agent-from-a-cloud-flow)).

Las tres opciones se midieron con el mismo agente del standard harness, con orquestación generativa y publicado, en el mismo entorno de la demo, con la misma herramienta (publica en un canal de Teams de pruebas y registra `T1` y `T2` en una lista sumidero).

## Resultados del spike (2026-10-09)

| Opción | Eventos | Perdidos | Reacción p50 | Reacción p90 | Tramo 2 p50 | Tramo 2 p90 | Tramo 2 máx | Veredicto |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| A | 3 | 0 | 35,0 s | 37,0 s | 38,0 s | 39,0 s | 39,0 s | No (corte p90) |
| B | — | — | — | — | — | — | — | No se midió |
| C | 20 | 0 | 3,9 s | 4,7 s | 7,1 s | 10,5 s | 14,1 s | **Cumple** |

- **A** se cortó a los 3 eventos (corte p90 agresivo). La página *Activity* del agente mostró que el disparador de SharePoint tarda unos 33 s en entregar el evento; el agente decide en unos 2 s y la herramienta tarda unos 3,6 s.
- **B** no se midió: la regla del spike permite saltarla cuando otra opción ya cumple, y la cuenta de servicio no tenía permiso para crear tablas en el entorno.
- **C** cumplió con margen: p90 de 10,5 s, la mitad del presupuesto, sin eventos perdidos. Los dos eventos más lentos (14,1 s y 13,7 s) se explican por la publicación en Teams, no por la reacción del agente (≤ 5,1 s en los 20 eventos).

Notas de medición: `T0` es la hora local del envío HTTP (desfase con el reloj de SharePoint medido en 0 s); `T1` y `T2` tienen resolución de 1 s. Los CSV crudos quedan en `spikes/p1-latencia/resultados/`, que no se versiona.

## Decisión

El agente se dispara con un **flujo del agente con disparador HTTP** que recibe el `eventId` y llama a **Ejecutar agente** (sin esperar la respuesta). La lista de SharePoint sigue siendo el registro de auditoría (DEC-02): la Function primero crea el elemento y después llama al flujo.

Configuración recomendada para el Plan:

1. **Autenticación del disparador:** *Usuarios específicos de mi inquilino* con el **object ID de la identidad administrada de la Function** como único autorizado. Learn admite object IDs de entidades de servicio en esa lista ([OAuth authentication for HTTP request triggers](https://learn.microsoft.com/power-automate/oauth-authentication)). Así no hay URL con firma (SAS) que proteger y solo la Function puede disparar al agente. En el spike se usó *Cualquier usuario de mi inquilino* porque el emisor era la CLI de Daniel.
2. **Token:** audiencia exacta `https://service.flow.microsoft.com/`, con la barra final ([Audience values](https://learn.microsoft.com/power-automate/oauth-authentication#audience-values)). Con `https://api.powerplatform.com` el servicio respondió HTTP 500.
3. **Mensaje al agente:** solo el `eventId`; el agente lee el incidente de la lista con su herramienta. Así el registro de auditoría es la única fuente de los datos del incidente.
4. **Idempotencia:** si la Function reintenta la llamada, el flujo `PublicarIncidente` no vuelve a publicar un incidente que ya no esté en estado `Nuevo` (condición 3 de DEC-01).

## Consecuencias

- **A favor:** latencia holgada para OBJ-2 (queda margen de unos 20 s para el tramo 1 y la variación del día del evento); el disparo deja de depender del sondeo del conector de SharePoint; no requiere Dataverse.
- **En contra:** una pieza más (el flujo HTTP) y una llamada saliente más desde la Function, con su reintento y su registro en Application Insights (RNF-04).
- **Riesgo para el Plan:** el spike se disparó con un token de usuario. Antes de E3 hay que probar el disparo con el token de la identidad administrada de la Function; si no funciona, la alternativa es una entidad de servicio con certificado en Key Vault, nunca un secreto en el repositorio.
- **Créditos:** cada evento consume una ejecución del agente más las acciones del flujo; el límite por agente de ADR-001 sigue aplicando.
- **Idioma:** los disparadores de evento exigen un agente en `en-US` ([Language support](https://learn.microsoft.com/microsoft-copilot-studio/authoring-language-support)). La opción C no usa disparadores de evento, pero el agente de la demo se crea igual en `en-US` con instrucciones de responder en español, para no cerrar la puerta a A o B si el Plan las necesita.

## Opciones descartadas

- **A (disparador de SharePoint):** p90 de 39 s solo en el tramo 2; con eso OBJ-2 es imposible sin relajarlo.
- **B (disparador de Dataverse):** no se midió porque C ya cumple y es más simple de operar para este caso (no necesita tabla, rol ni capacidad de Dataverse adicionales).
