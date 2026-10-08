# Clarificaciones de la especificación — Fase 1

| Campo | Valor |
| --- | --- |
| Versión | 1.0 |
| Fecha | 2026-10-08 |
| Autor | Equipo (rol: lider-especificacion) |
| Estado | Respondido por Daniel el 2026-10-08; incorporado en `01-especificacion.md` v1.1 (ver su registro de cambios) |
| Documentos revisados | `docs/reglas-del-proyecto.md`, `specs/00-constitucion.md`, `specs/01-especificacion.md` v1.0, plan de sesión, `equipo/*.md` |

Este documento no cambia la especificación. Lista lo que encontramos, lo que proponemos suponer y lo que necesitamos que decidas. Con tus respuestas se actualiza `01-especificacion.md` a la versión 1.1.

---

## 1. Resumen ejecutivo

La especificación es consistente con la constitución y el plan de sesión, y casi todos los criterios son verificables. Al contrastarla con Microsoft Learn aparecen **tres hallazgos que pueden romper la demo** si no se deciden ahora:

1. **Latencia del disparador de SharePoint (crítico).** El disparador "Cuando se crea un elemento" es de tipo *polling* en Power Platform. Microsoft Learn documenta intervalos de varios minutos según la licencia y **no documenta el intervalo para disparadores de agentes de Copilot Studio**. OBJ-2 (≤ 30 s, nunca > 60 s) no está garantizado con la arquitectura actual. → Pregunta P1.
2. **El disparador de IoT Hub en Azure Functions no admite identidad administrada.** Exige una cadena de conexión. Choca con "identidades administradas" (Art. 4) salvo que la guardemos como referencia a Key Vault o agreguemos un Event Hub. → Pregunta P2.
3. **Copilot Studio ahora tiene "harnesses".** Los disparadores de evento y el conector de Power Automate están documentados para el *standard harness*; el conector no admite agentes del *GitHub Copilot harness*. Hay que fijar el harness en la especificación. → Pregunta P3.

Para **DEC-01** ya hay una vía verificada y simple (ver §5): un flujo del agente que responde al agente de inmediato y, **después** de "Responder al agente", publica la tarjeta y espera la decisión. Learn confirma que las acciones posteriores a la respuesta pueden seguir corriendo hasta 30 días.

---

## 2. Preguntas abiertas (máximo 10, por prioridad)

Cada pregunta trae nuestra recomendación para que puedas responder solo "sí" o elegir una letra.

### P1. Latencia de punta a punta frente al disparador por *polling* — CRÍTICA
**Contexto.** Learn: los disparadores *polling* "despiertan periódicamente"; en flujos de Power Automate con licencias de Office 365 el intervalo es de 5 minutos y en el plan gratuito de 15 ([Troubleshoot triggers](https://learn.microsoft.com/troubleshoot/power-platform/power-automate/flow-run-issues/triggers-troubleshoot#trigger-firing-is-delayed)). Para los disparadores de evento de Copilot Studio no hay un intervalo documentado ([Event trigger overview](https://learn.microsoft.com/microsoft-copilot-studio/authoring-triggers-about)).
**Afecta:** OBJ-2, RNF-01, CA-14.3, guion del acto 1.
**Opciones:**
- **(a)** Mantener SharePoint → disparador del agente (el diseño del plan de sesión) y **medir en tu tenant con una prueba exploratoria (spike) antes de la Fase 2**. Si la mediana es > 30 s, se relaja OBJ-2 o se pasa a (b).
- **(b)** Function → flujo de nube con disparador HTTP (instantáneo, *webhook*) → acción **Execute Agent** del conector de Copilot Studio ([Call Copilot Studio agents from Power Automate](https://learn.microsoft.com/power-automate/call-copilot-studio-agent)). La lista sigue siendo el registro de auditoría. Requiere licencia premium de Power Automate y guardar la URL del disparador (secreto) en Key Vault. Es la alternativa que el plan de sesión menciona "para volúmenes altos".
- **(c)** Relajar OBJ-2 a "≤ 2 min" y llenar la espera en vivo con la explicación del agente (el plan B ya lo contempla).

**Recomendación:** (a) con un spike de 30 minutos en tu tenant esta semana; (b) como plan de respaldo ya diseñado en el ADR de DEC-02.

### P2. Credencial del disparador de IoT Hub
**Contexto.** Learn: "The IoT Hub trigger doesn't support identity-based connections" ([IoT Hub trigger](https://learn.microsoft.com/azure/azure-functions/functions-bindings-event-iot-trigger#connections)). El punto de conexión integrado solo se lee con clave de acceso compartido ([Control access to IoT Hub by using Microsoft Entra ID](https://learn.microsoft.com/azure/iot-hub/authenticate-authorize-azure-ad#permissions-for-iot-hub-service-apis)).
**Afecta:** CA-04.1, CA-04.4, Art. 4, costos.
**Opciones:**
- **(a)** Cadena de conexión con permiso solo de lectura (`service`), guardada en Key Vault y referenciada desde la configuración de la Function (sin texto plano). Costo adicional: 0.
- **(b)** Enrutamiento de IoT Hub a un Event Hub propio con identidad administrada de punta a punta. Más "puro", agrega un recurso y costo mensual (Event Hubs Basic) y un salto más de latencia.

**Recomendación:** (a), documentada en un ADR y en `docs/gobernanza.md` como deuda consciente.

### P3. Harness de Copilot Studio
**Contexto.** Learn documenta los disparadores de evento, los flujos del agente y la respuesta asíncrona para el *standard harness* ([Harnesses](https://learn.microsoft.com/microsoft-copilot-studio/harnesses-overview)). El conector de Power Automate no admite agentes del *GitHub Copilot harness* ([Call agents from Power Automate](https://learn.microsoft.com/power-automate/call-copilot-studio-agent)). Un agente no se puede pasar de un harness a otro.
**Recomendación:** fijar **standard harness** en la especificación (HU-08) y en la guía, indicando cómo crearlo ("Other ways to build" / experiencia clásica, [Access standard harness agents](https://learn.microsoft.com/microsoft-copilot-studio/agents-experience/switch-experiences)). ¿De acuerdo?

### P4. Licenciamiento disponible en tu tenant
Necesitamos saber qué tienes para no diseñar sobre algo que no existe:
- Copilot Studio: ¿prueba, paquete de Copilot Credits o pago por uso (PAYG) en el entorno?
- ¿Las cuentas de la demo tienen licencia de Microsoft 365 Copilot? (cambia si ciertas ejecuciones consumen créditos, ver [Billing rates](https://learn.microsoft.com/microsoft-copilot-studio/requirements-messages-management#copilot-credits-billing-rates)).
- ¿Tienes Power Automate premium? (requisito de P1-b).
- ¿El entorno de Power Platform está en la "nueva infraestructura"? (requisito de la respuesta asíncrona y del modo exprés).

### P5. Escala y cálculo de severidad
La especificación usa `rawSeverity` (dispositivo), `severity` (función, CA-05.1) y "severidad final" (agente, CA-08.1/08.2) sin definir la escala ni la relación entre ellas.
**Propuesta:**
- Escala única de 4 niveles en texto: `Baja`, `Media`, `Alta`, `Crítica` (RNF-07: no solo color).
- La función calcula `SeveridadInicial` = máx(`rawSeverity`, severidad base de la zona en `data/zonas.json`).
- El agente calcula `SeveridadPropuesta` = `SeveridadInicial` + 1 nivel fuera de horario (tope `Crítica`). Son dos columnas distintas en la lista para que se vea qué hizo cada componente.

¿Apruebas la propuesta?

### P6. Zona horaria y horario de la regla
CA-08.2 dice "06:00–18:00 hora local" y CA-09.2 "hora local". ¿Qué zona? **Propuesta:** `America/Bogota` (UTC−5, sin horario de verano) fija en el catálogo por sitio, y el evento siempre en UTC. ¿Confirmas, o el público y la demo usan otra zona?

### P7. Sensor físico (HU-03, Could)
El plan de sesión pide decidirlo. ¿Lo incluimos? Si sí: ¿tienes Raspberry Pi (modelo) y sensor PIR o contacto magnético? **Recomendación:** dejarlo fuera del alcance comprometido y hacerlo solo si E1–E4 terminan antes del 25 de octubre.

### P8. Prueba de CA-06.2 (escritura denegada en otro sitio) y administrador del tenant
CA-06.2 requiere un **segundo sitio** de SharePoint sin permiso para la función. ¿Podemos crear un sitio "control" vacío en tu tenant? Además: ¿quién concede `Sites.Selected` y el rol de aplicación a la identidad administrada (tú como administrador global u otra persona), y cuándo está disponible?

### P9. Repositorio público y CI
RNF-06 pide GitHub Actions. ¿Nombre y cuenta u organización del repositorio? ¿Lo publicamos desde ya o se mantiene privado hasta el evento? **Propuesta:** privado hasta el ensayo general, público el día del evento.

### P10. Región de Azure y fechas de congelamiento
- Región: **propuesta** `eastus2` (Flex Consumption y IoT Hub disponibles; verificar en el Plan). ¿Prefieres otra por latencia desde Colombia?
- Fecha de congelamiento de la demo (sin cambios de código después): **propuesta** 28 de octubre de 2026, una semana antes del evento.

---

## 3. Ambigüedades y supuestos propuestos

Si no dices lo contrario, estos supuestos entran en la versión 1.1 de la especificación.

| ID | Criterio | Ambigüedad | Supuesto propuesto |
| --- | --- | --- | --- |
| S-01 | CA-01.1 | `simulate` como comando: ¿script, módulo o ejecutable? | Paquete Python con *entry point* `simulate`; también funciona `python -m simulator`. |
| S-02 | CA-01.3 | "Ningún campo contiene datos personales" no es verificable tal cual. | Esquema con `additionalProperties: false` y patrones cerrados (`deviceId` = `DEV-[A-Z0-9-]+`, `zone` = `Z-\d{2}`); la prueba valida contra el esquema. |
| S-03 | CA-02.1 / CA-12.1 | ¿El límite de 10 incidentes por minuto cuenta las actualizaciones de `Repeticiones`? | No. Solo cuenta creaciones de incidentes; las repeticiones de un incidente existente siempre se acumulan. |
| S-04 | CA-05.2 | Ventana de 60 s: ¿fija desde el primer evento o deslizante? | Fija desde el primer evento del incidente. Pasados 60 s, un nuevo evento crea otro incidente. |
| S-05 | CA-05.2 / DEC-04 | La deduplicación en memoria se rompe si Flex Consumption escala a varias instancias o reinicia. | Se recomienda Table Storage con concurrencia optimista (ETag) en el ADR de DEC-04; el costo es despreciable. |
| S-06 | CA-02.2 | ¿Repeticiones = 20 se escribe en un solo paso o se actualiza el elemento? | La función crea el elemento con el primer evento y actualiza `Repeticiones` (PATCH vía Graph). El disparador solo reacciona a la creación, así que el agente se ejecuta una vez. |
| S-07 | CA-05.5 | Cómo se mide "≤ 10 s". | Diferencia entre `enqueuedTimeUtc` de IoT Hub y la respuesta de Graph al crear el elemento, registrada en Application Insights con `eventId`; consulta KQL versionada. |
| S-08 | CA-05.4 | "Cobertura ≥ 80 % en ese módulo". | `pytest --cov=function/core --cov-fail-under=80`, con la lógica pura separada de los *bindings*. |
| S-09 | CA-07.3 / CA-08.3 | Formato de los protocolos para conocimiento de SharePoint. | Fuente en Markdown en `protocols/`; el script de aprovisionamiento sube versiones `.docx` generadas. Se verifica en el Plan qué formatos indexa Copilot Studio desde SharePoint. |
| S-10 | CA-09.2 | "Máximo 3 líneas". | `TextBlock` con `wrap: true` y `maxLines: 3`; el agente recibe la instrucción de no pasar de 3 frases. |
| S-11 | CA-09.4 | Esquema "en la versión soportada por Teams". | Adaptive Cards **1.5** (Learn: Teams escritorio, web y móvil, [Adaptive Cards for agent design](https://learn.microsoft.com/agents/design-guidelines/adaptive-cards-for-agent-design#schema-and-host-compatibility)); solo `Action.Submit` (no `Action.Execute`), sin `isEnabled` (no soportado en Teams). Validación con `jsonschema` contra copia versionada del esquema oficial. |
| S-12 | CA-09.1 / CA-10.2 | "Sin plantillas" y versión de solo lectura. | Las tarjetas se arman con expresiones de Power Automate, no con *templating* (Learn: Power Automate no lo soporta, [Proactive messages](https://learn.microsoft.com/microsoft-copilot-studio/advanced-proactive-message)). La versión de solo lectura es el "Update message" de la acción de espera. |
| S-13 | CA-10.1 | Valores de `Estado`. | `Nuevo` (función) → `Pendiente de decisión` (flujo del agente) → `Atendido` / `Escalado` / `Falsa alarma` (persona). |
| S-14 | CA-10.1 | `DecididoPor` guarda un dato de una persona del tenant. | Se usan cuentas de prueba con nombres ficticios ("Supervisor Demo"). Se guarda el nombre para mostrar que devuelve la acción de espera. |
| S-15 | CA-14.2 | "Deja la lista vacía". | El script de reinicio borra los elementos (van a la papelera de reciclaje del sitio, no se eliminan permanentemente) con tu identidad delegada, no con la de la función. |
| S-16 | CA-14.3 | "El disparador responde" no se puede consultar por API. | El preflight crea un incidente de prueba marcado `EsPrueba = Sí` y espera a que `Estado` cambie a `Pendiente de decisión`; si no cambia en el tiempo límite, ese componente sale en rojo. |
| S-17 | RNF-05 | Herramienta de escaneo de secretos. | `gitleaks` en GitHub Actions. |
| S-18 | CA-04.1 | Solo hay un IoT Hub gratuito por suscripción ([límites](https://learn.microsoft.com/azure/iot-hub/iot-hub-devguide-quotas-throttling)). | Parámetro `iotHubSku` con valor por defecto `F1`; si ya existe uno gratuito, `B1`. El documento de costos muestra ambos casos. |
| S-19 | CA-08.5 | "5 de 5 casos": el modelo no es determinista. | Tabla de 5 casos en `agent/casos-prueba.md`; se ejecuta 3 veces cada caso en tu tenant; cumple si 5/5 coinciden en al menos 2 de 3 corridas. Esto se te propone explícitamente porque cambia el criterio. |
| S-20 | CA-11.2 | Página "Monitor" de Copilot Studio. | Se verifica su nombre y alcance en Learn durante el Plan; si no existe con ese nombre, se ajusta el texto. |

---

## 4. Inconsistencias encontradas

| ID | Dónde | Problema | Corrección propuesta |
| --- | --- | --- | --- |
| I-01 | OBJ-2 vs CA-05.5 | OBJ-2 mide evento → tarjeta en Teams (≤ 30 s); CA-05.5 solo cubre IoT Hub → SharePoint (≤ 10 s). Falta presupuestar el tramo SharePoint → agente → Teams, que es el que tiene el riesgo de *polling*. | Agregar CA-08.6: "SharePoint → tarjeta visible ≤ 20 s en el 90 % de 10 ensayos", o el valor que resulte de P1. |
| I-02 | CA-08.3 vs plan de sesión | La especificación habla de "la herramienta que publica la tarjeta"; el plan de sesión, de "flujo del agente" que espera la decisión. Un flujo del agente que espera a una persona excede el límite de 100 s. | Resolver con DEC-01 (ver §5) y redactar CA-08.3 como "el flujo del agente `PublicarIncidente`". |
| I-03 | HU-06 | La función usa identidad administrada, pero `Sites.Selected` se concede como rol de aplicación a la identidad (no hay registro de aplicación ni consentimiento en el portal). | CA-06.4 debe documentar dos comandos: asignar el rol de aplicación `Sites.Selected` de Microsoft Graph a la identidad administrada ([PowerShell](https://learn.microsoft.com/entra/identity/managed-identities-azure-resources/assign-app-role-managed-identity-powershell)) y crear el permiso `write` sobre el sitio (`POST /sites/{siteId}/permissions`, [Selected permissions](https://learn.microsoft.com/graph/permissions-selected-overview)). |
| I-04 | CA-12.3 / HU-12 | La regla de créditos solo menciona el disparador. Por incidente también se cobran acciones del agente, respuesta generativa con conocimiento y acciones del flujo. | Ampliar CA-12.3 para que el README estime los créditos por incidente con la tabla oficial de tarifas. |
| I-05 | Art. 1 vs botón "Falsa alarma" | La constitución dice que el agente nunca cierra un caso como falsa alarma. El botón lo pulsa la persona, así que es coherente, pero la tarjeta debe dejarlo claro. | CA-09.5 se amplía: las acciones se rotulan como decisiones del supervisor ("Yo atiendo", etc.) y el texto de confirmación dice "Decisión registrada; nadie fue contactado". |
| I-06 | docs/reglas-del-proyecto.md "Comandos útiles" | `az bicep lint` no recibe `--file infra/main.bicep` en todas las versiones de la CLI. | Se fija la versión de Bicep en el Plan y se prueba el comando exacto. |

---

## 5. Avance verificado sobre DEC-01 (para el ADR del Plan)

Hechos confirmados en Microsoft Learn:
- Un flujo usado como herramienta del agente debe responder en **100 s** ("Respond to the agent within the 100-second action limit") y **"las acciones que necesitan más tiempo pueden ir después de *Respond to the agent* y seguir hasta el límite de 30 días"** ([Create an agent flow as a tool](https://learn.microsoft.com/microsoft-copilot-studio/advanced-flow-create)).
- Existe la **respuesta asíncrona**, pero solo en entornos con la nueva infraestructura ([Asynchronous response](https://learn.microsoft.com/microsoft-copilot-studio/flow-asynchronous-response)).
- La acción del conector de Teams **"Post an adaptive card to a Teams channel and wait for a response"** espera la respuesta de cualquier miembro del canal, acepta una sola respuesta por tarjeta y reemplaza la tarjeta con el "Update message" ([Adaptive cards for Teams](https://learn.microsoft.com/power-automate/overview-adaptive-cards#known-issues)).

Opción preferida a llevar al ADR: **flujo del agente con respuesta inmediata**: `When an agent calls the flow` → actualizar `Estado = Pendiente de decisión` → `Respond to the agent` → `Post adaptive card in a chat or channel and wait for a response` (canal *Centro de operaciones*, como Flow bot) → actualizar el elemento con la decisión. No depende de la nueva infraestructura y no choca con el límite de 100 s.

Riesgo abierto: la tarjeta la publica el *Flow bot* (Workflows), no el agente. Para "publicar como agente" Learn solo documenta el destino "Chat with agent" (chat 1:1), no un canal. Se acepta que en el canal aparezca como Workflows, salvo que prefieras otra cosa.

---

## 6. Capacidades de Microsoft a verificar (Art. 8)

| ID | Capacidad | Estado | Fuente |
| --- | --- | --- | --- |
| V-01 | Disparadores de evento de Copilot Studio (incluye "When an item is created" de SharePoint), solo con orquestación generativa | Verificado | [Event trigger overview](https://learn.microsoft.com/microsoft-copilot-studio/authoring-triggers-about) |
| V-02 | Los disparadores usan solo las credenciales del creador; advertencia al publicar | Verificado | [Add an event trigger](https://learn.microsoft.com/microsoft-copilot-studio/authoring-trigger-event) |
| V-03 | Los administradores bloquean disparadores con políticas de datos (conector Microsoft Copilot Studio) | Verificado | [Configure data policies](https://learn.microsoft.com/microsoft-copilot-studio/admin-data-loss-prevention) |
| V-04 | Agregar disparadores requiere "solution-aware cloud flow sharing" activo en el entorno | Verificado (nuevo requisito para la guía) | [Event trigger overview](https://learn.microsoft.com/microsoft-copilot-studio/authoring-triggers-about#troubleshooting-and-limitations) |
| V-05 | Página Activity registra disparadores y reacciones | Verificado | [Add an event trigger](https://learn.microsoft.com/microsoft-copilot-studio/authoring-trigger-event#publish-an-agent-with-a-trigger) |
| V-06 | Límite de 100 s de los flujos del agente; acciones posteriores hasta 30 días | Verificado | [Agent flow as a tool](https://learn.microsoft.com/microsoft-copilot-studio/advanced-flow-create) |
| V-07 | Respuesta asíncrona de flujos del agente (solo nueva infraestructura) | Verificado | [Asynchronous response](https://learn.microsoft.com/microsoft-copilot-studio/flow-asynchronous-response) |
| V-08 | Teams: tarjeta en canal y esperar respuesta; una respuesta por tarjeta; "Update message" | Verificado | [Adaptive cards for Teams](https://learn.microsoft.com/power-automate/overview-adaptive-cards) |
| V-09 | Power Automate no soporta *templating* de Adaptive Cards | Verificado | [Proactive messages](https://learn.microsoft.com/microsoft-copilot-studio/advanced-proactive-message) |
| V-10 | Teams soporta Adaptive Cards 1.5 | Verificado | [Adaptive Cards for agent design](https://learn.microsoft.com/agents/design-guidelines/adaptive-cards-for-agent-design#schema-and-host-compatibility) |
| V-11 | Tarifas de Copilot Credits (acción del agente 5, respuesta generativa 2, flujo 13 por 100 acciones) | Verificado | [Billing rates](https://learn.microsoft.com/microsoft-copilot-studio/requirements-messages-management#copilot-credits-billing-rates) |
| V-12 | Límite mensual de créditos por agente en el centro de administración | Verificado | [Billing rates — overage](https://learn.microsoft.com/microsoft-copilot-studio/requirements-messages-management#overage-enforcement) |
| V-13 | `Sites.Selected` + `POST /sites/{id}/permissions` con rol `write` | Verificado | [Selected permissions overview](https://learn.microsoft.com/graph/permissions-selected-overview) |
| V-14 | Asignar rol de aplicación de Graph a identidad administrada | Verificado | [Assign app role to managed identity](https://learn.microsoft.com/entra/identity/managed-identities-azure-resources/assign-app-role-managed-identity-powershell) |
| V-15 | IoT Hub F1: 8 000 mensajes/día, 1 por suscripción, mensajes de 0,5 KB para la cuota | Verificado | [Quotas and throttling](https://learn.microsoft.com/azure/iot-hub/iot-hub-devguide-quotas-throttling) |
| V-16 | Trigger de IoT Hub sin conexión basada en identidad | Verificado (riesgo R-02) | [IoT Hub trigger](https://learn.microsoft.com/azure/azure-functions/functions-bindings-event-iot-trigger#connections) |
| V-17 | Flex Consumption: instancias *always ready* para mitigar arranque en frío | Verificado | [Flex Consumption](https://learn.microsoft.com/azure/azure-functions/flex-consumption-plan#always-ready-instances) |
| V-18 | Intervalo de *polling* del disparador de SharePoint en agentes de Copilot Studio | **No documentado** (riesgo R-01) | — |
| V-19 | Referencias a Key Vault en configuración de Function App en Flex Consumption | Pendiente (Plan) | — |
| V-20 | Formatos de archivo indexados por conocimiento de SharePoint en Copilot Studio | Pendiente (Plan) | — |
| V-21 | Página "Monitor" de Copilot Studio y su alcance | Pendiente (Plan) | — |
| V-22 | Disponibilidad de Flex Consumption + Python 3.11/3.12 en la región elegida | Pendiente (Plan) | — |
| V-23 | Execute Agent: disponibilidad y licencia requerida (opción P1-b) | Verificado parcialmente | [Call agents from Power Automate](https://learn.microsoft.com/power-automate/call-copilot-studio-agent) |

---

## 7. Riesgos técnicos

| ID | Riesgo | Prob. | Impacto | Mitigación |
| --- | --- | --- | --- | --- |
| R-01 | Disparador de SharePoint tarda minutos → no se cumple OBJ-2 en vivo | Alta | Alto | P1: spike de medición; plan B (b) diseñado; video del acto 1 |
| R-02 | Cadena de conexión de IoT Hub expuesta | Media | Alto | Key Vault + permiso solo `service` + rotación en `demo/reset`; nunca en el repo |
| R-03 | Créditos agotados o agente deshabilitado al 125 % de la capacidad el día del evento | Baja | Alto | Deduplicación + límite por minuto en Azure; límite mensual por agente; revisar consumo en el preflight |
| R-04 | Conexiones del creador vencidas en vivo | Media | Alto | Reautenticar 1 h antes (checklist); preflight end-to-end |
| R-05 | Política DLP o "solution-aware cloud flow sharing" desactivado en el entorno | Media | Alto | Entorno dedicado; paso explícito en la guía y en el preflight |
| R-06 | Arranque en frío de Flex Consumption suma segundos | Media | Medio | `always ready = 1` solo durante ensayos y evento (parámetro); 0 el resto del mes por costo |
| R-07 | Deduplicación inconsistente con varias instancias | Media | Medio | Table Storage con ETag (DEC-04) |
| R-08 | Respuestas del agente no deterministas (severidad o protocolo distintos) | Media | Medio | Severidad base calculada por la función; regla de horario explícita; casos de prueba repetidos (S-19) |
| R-09 | La tarjeta aparece como "Workflows" y no como el agente | Alta | Bajo | Explicarlo en la charla como decisión de diseño; documentado en el ADR |
| R-10 | Cambios del producto entre hoy y el 4 de noviembre (p. ej. harnesses) | Media | Medio | Fecha de congelamiento (P10); revisar Learn en el ensayo general |
| R-11 | Retraso del administrador del tenant para `Sites.Selected` | Media | Alto | Pedir el permiso esta semana (P8) |

---

## 8. Próximo paso

Respóndeme P1 a P10 (basta con "de acuerdo con la recomendación" en las que aceptes la propuesta) y dime si algún supuesto S-xx o corrección I-xx no te sirve. Con eso actualizo `specs/01-especificacion.md` a la versión 1.1 y quedo esperando tu **"aprobado fase 1"** para empezar el Plan.
