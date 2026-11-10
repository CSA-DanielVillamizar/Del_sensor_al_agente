# Ampliación de alcance: IA DAY 2026

**Estado:** aprobada por Daniel el 2026-11-09 ("aprobado fase 1 de IA Day"), con las recomendaciones de las decisiones DEC-IA-01 a DEC-IA-04.
**Fecha:** 2026-11-09.
**Evento:** IA DAY by Datly Educación, oficinas de Microsoft en Medellín, 27 de noviembre de 2026, 45 minutos, foco en IA y datos.
**Charla:** "Un agente vale lo que valen sus datos". Del sensor a la decisión: contrato, calidad y trazabilidad en un caso real.

## 1. Por qué cambia el alcance

La solución de "Del sensor al agente" se vuelve a usar para un público de datos. La tesis de la charla es que el trabajo de datos se hace antes del agente: contrato, validación, deduplicación, contexto y registro de la decisión humana. Para mostrarlo en vivo hacen falta dos piezas nuevas:

1. **Una ruta analítica**: los eventos crudos y los incidentes deduplicados, consultables con KQL.
2. **Un agente sobre datos estructurados**: Dataverse como conocimiento del agente, con preguntas sobre un histórico ficticio.

Todo lo existente se mantiene. La ampliación **no modifica** la Function, los esquemas ni la solución exportada en `agent/solucion/`.

## 2. Historias de usuario nuevas

### HU-15. Ruta analítica de los eventos
**Como** asistente de la charla, **quiero** ver los eventos crudos frente a los incidentes que llegan al agente, **para** entender cuánto reduce el pipeline antes de la IA.

- **CA-15.1** Una consulta KQL muestra, para la ráfaga de 20 eventos, 20 eventos recibidos y 1 incidente creado con 19 repeticiones.
- **CA-15.2** Una consulta KQL detecta una zona con comportamiento anómalo en un histórico ficticio, con `series_decompose_anomalies()`.
- **CA-15.3** La ruta analítica lee de su propio grupo de consumidores de IoT Hub y no cambia el código de la Function.
- **CA-15.4** La ruta se monta con un script o una guía paso a paso y se elimina con un comando o un paso documentado.

### HU-16. Agente sobre datos estructurados
**Como** asistente, **quiero** ver al agente responder sobre una tabla de incidentes, **para** entender que la calidad del metadato también es calidad del dato.

- **CA-16.1** En el entorno de desarrollo, una tabla de Dataverse tiene un histórico ficticio de incidentes de 30 días, cargado con un script reproducible.
- **CA-16.2** El agente responde en el panel de prueba de Copilot Studio a 3 preguntas de la guía con datos correctos de la tabla.
- **CA-16.3** Con las descripciones de columna "ensuciadas", la misma pregunta da una respuesta peor; el estado limpio se restaura con un comando.
- **CA-16.4** Ni la tabla ni el agente contienen datos personales reales (artículo 5).

### HU-17. Material de la charla
**Como** speaker, **quiero** el guion, la presentación y el runbook de los 45 minutos, **para** dar la charla sin depender de la red.

- **CA-17.1** El guion tiene tiempos por bloque que suman 45 minutos y 3 anécdotas con fuente verificable.
- **CA-17.2** La demo local (`pytest`, simulador) funciona sin conexión.
- **CA-17.3** Cada parte en vivo tiene un video de respaldo.
- **CA-17.4** El repositorio tiene una ruta "solo datos" documentada para el asistente, que se sigue en 20 minutos sin licencias.

## 3. Decisiones que necesitan aprobación

| ID | Decisión | Opciones | Recomendación |
| --- | --- | --- | --- |
| DEC-IA-01 | Dónde corre la ruta analítica | **A.** Fabric Real-Time Intelligence (Eventstream y Eventhouse) con la prueba gratuita de 60 días. **B.** KQL sobre Application Insights, que ya recibe `EventRejected`, `IncidentCreated` y `RepetitionCounted` | **A**, porque le habla directo a un público de datos. **B** queda como plan B: ya existe y no cuesta nada más |
| DEC-IA-02 | Cómo se autentica Eventstream ante IoT Hub (solo con A) | La fuente IoT Hub de Eventstream usa una política de acceso compartido ([Learn](https://learn.microsoft.com/fabric/real-time-intelligence/event-streams/add-source-azure-iot-hub)) | Política dedicada solo con `ServiceConnect`. La clave vive en la conexión de Fabric, nunca en el repositorio. Revisión obligatoria de `revisor-seguridad` |
| DEC-IA-03 | De dónde sale el histórico de Dataverse | **A.** Script que genera 30 días de incidentes ficticios y los carga por la API web. **B.** Flujo que copia desde la lista de SharePoint | **A**: determinista, reproducible y sin consumir ejecuciones de flujo |
| DEC-IA-04 | Licencia de Copilot Studio para la demo | Prueba individual vigente de la cuenta del speaker y de `agente-dsa`: crea y prueba, pero no publica ([Learn](https://learn.microsoft.com/microsoft-copilot-studio/requirements-licensing-subscriptions#sign-up-for-a-copilot-studio-trial)) | Usarla. Si el panel de prueba no responde con orquestación generativa, la parte 3 pasa a video |

## 4. Entorno y costo

| Pieza | Dónde | Costo estimado |
| --- | --- | --- |
| Azure (IoT Hub, Function, monitoreo) | Suscripción de Azure de la demo, recreada con `infra/deploy.ps1` | Centavos, dentro del presupuesto de USD 20 al mes (artículo 9) |
| Fabric | Prueba gratuita de 60 días de la cuenta del speaker ([Learn](https://learn.microsoft.com/fabric/fundamentals/fabric-trial)) | USD 0 |
| Dataverse | Entorno de desarrollo "DSA IA Day - Desarrollo", creado el 2026-11-09. Se suspende el 2026-12-15 ([Learn](https://learn.microsoft.com/power-platform/developer/plan#faq)) | USD 0 |
| Copilot Studio | Prueba individual vigente | USD 0 |

Después del evento, Azure se elimina con `infra/destroy.ps1`, la prueba de Fabric se termina o vence sola y el entorno de desarrollo se suspende solo.

## 5. Tareas propuestas

| ID | Tarea | HU / CA | Responsable | Depende de |
| --- | --- | --- | --- | --- |
| T-057 | Volver a desplegar Azure en la suscripción de la demo y registrar los dispositivos | HU-15 / CA-15.3 | arquitecto-cloud | Aprobación |
| T-058 | Grupo de consumidores `fabric` y política `ServiceConnect` dedicada en `infra/` (Bicep) | HU-15 / CA-15.3 | arquitecto-cloud, revisor-seguridad | T-057, DEC-IA-02 |
| T-059 | Activar la prueba de Fabric, crear el área de trabajo, Eventstream y Eventhouse; guía en `analytics/README.md` | HU-15 / CA-15.4 | arquitecto-cloud | T-058 |
| T-060 | Consultas KQL de la charla en `analytics/kql/`: ráfaga, crudos frente a incidentes, anomalías | HU-15 / CA-15.1, CA-15.2 | arquitecto-cloud | T-059 |
| T-061 | Generador del histórico ficticio y carga en Dataverse (`analytics/dataverse/`), con pruebas | HU-16 / CA-16.1, CA-16.4 | arquitecto-m365 | Aprobación |
| T-062 | Agente "Analista de Incidentes" en el entorno de desarrollo, con la tabla como conocimiento; script para ensuciar y restaurar las descripciones | HU-16 / CA-16.2, CA-16.3 | arquitecto-m365 | T-061 |
| T-063 | Guion, presentación y runbook de la charla en `presentacion/ia-day/` (no versionado) | HU-17 / CA-17.1, CA-17.2 | instructor-tecnico | T-060, T-062 |
| T-064 | Ruta "solo datos" para el asistente en `docs/ruta-datos.md` | HU-17 / CA-17.4 | instructor-tecnico | — |
| T-065 | Grabar los videos de respaldo de las partes 2 y 3 | HU-17 / CA-17.3 | Daniel | T-060, T-062 |
| T-066 | Revisión de seguridad de la ampliación y ensayo cronometrado completo | HU-15 a HU-17 | revisor-seguridad, qa-verificacion | T-063, T-065 |

## 6. Calendario

| Fecha | Hito |
| --- | --- |
| 10–12 nov | T-057, T-058, T-061 y T-064 |
| 13–17 nov | T-059, T-060 y T-062 |
| 18–21 nov | T-063 y T-065 |
| 24–25 nov | T-066: revisión y dos ensayos completos |
| 26 nov | Preflight y congelamiento |
| 27 nov | Charla |

## 7. Comprobación contra la constitución

- **Artículo 1:** el agente nuevo solo consulta y responde. No ejecuta acciones.
- **Artículo 4:** la clave de la política de IoT Hub no entra al repositorio; la Function no cambia.
- **Artículo 5:** el histórico es ficticio y se genera con un script.
- **Artículo 7:** cada parte en vivo tiene video de respaldo y comando de reinicio.
- **Artículo 8:** cada capacidad lleva su enlace a Learn. Lo no verificado (que el panel de prueba responda con la prueba individual) está marcado como riesgo en DEC-IA-04.
- **Artículo 9:** Azure dentro de USD 20 al mes; Fabric, Dataverse y Copilot Studio en prueba.

## 8. Riesgos

| Riesgo | Mitigación |
| --- | --- |
| La prueba de Fabric no está disponible en el tenant | Plan B de DEC-IA-01: KQL sobre Application Insights |
| El panel de prueba no responde con la prueba individual | La parte 3 pasa a video |
| Chrome o la CLI quedan en la cuenta de otro tenant | Verificar el tenant antes de cada cambio |
| La red del evento falla | La demo local no depende de la red; las demás partes tienen video |
