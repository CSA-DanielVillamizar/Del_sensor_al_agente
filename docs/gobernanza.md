# Gobernanza del agente de operaciones

Guía para llevar el patrón "del sensor al agente" a producción sin abrir riesgos. Cubre HU-11 (CA-11.1 a CA-11.4). Describe la **configuración recomendada**; lo que cambia en la demo en vivo está en la sección "Desviaciones de la demo en vivo".

Regla de lectura: cada afirmación sobre Microsoft 365, Copilot Studio, Power Platform o Azure lleva su enlace a Microsoft Learn (consultado el 2026-10-26). Lo que Learn no confirma se marca como **riesgo** (R-G1 a R-G6, resumidos al final).

## 1. Qué se automatiza y qué decide siempre una persona

El agente clasifica, contextualiza y propone. La persona decide todo lo que afecta a otras personas o al mundo físico (constitución, artículo 1).

| Se automatiza | Lo decide siempre una persona |
| --- | --- |
| Recibir y deduplicar alertas | Llamar a la fuerza pública o a emergencias |
| Clasificar severidad inicial | Bloquear o abrir accesos físicos |
| Buscar el protocolo que aplica | Confrontar o retener a alguien |
| Redactar el resumen para el supervisor | Declarar una falsa alarma y cerrar el caso |
| Registrar quién decidió qué y cuándo | Cambiar el propio protocolo |

Cómo lo hace cumplir el diseño:

- **Nada sale del canal y de la lista.** El flujo `PublicarIncidente` no tiene ninguna acción de correo, llamada ni mensaje externo. La decisión "Escalar a autoridades" **solo se registra**; la llamada la hace una persona fuera del sistema ([ADR-008](adr/ADR-008-publicacion-tarjeta-y-decision.md), CA-10.3).
- **El agente no cierra casos.** Solo el supervisor, con un botón de la tarjeta, deja un incidente en `Atendido`, `Escalado` o `Falsa alarma`. Si nadie responde en 15 minutos, el estado pasa a `Sin respuesta`, no a "cerrado".
- **La propuesta del agente tiene un límite.** El agente puede proponer como máximo un nivel de diferencia con la severidad inicial, y el flujo lo comprueba antes de escribir.
- **Textos sin acciones físicas.** Las instrucciones y las tarjetas hablan de "propuesta" y de "decisión del supervisor". Ningún texto dice que el agente avisó, bloqueó o llamó a alguien (CA-09.5). Cualquier cambio de texto en `agent/` o `cards/` pasa por el revisor de seguridad.
- **Registro de quién, qué y cuándo.** `Decision`, `DecididoPor` y `FechaDecision` quedan en la lista `Eventos de seguridad`, que es el registro de auditoría ([ADR-004](adr/ADR-004-puente-azure-m365.md)).

## 2. Cuenta de servicio y credenciales del creador

**Qué dice Learn.** Los disparadores de evento y las acciones de un agente que corre solo usan **las credenciales de quien creó el agente**. Por eso, quien use el agente publicado puede llegar a datos y sistemas con esa misma autorización ([Event trigger overview: data protection](https://learn.microsoft.com/microsoft-copilot-studio/authoring-triggers-about#data-protection-for-agents-with-triggers)). Esta solución no usa disparadores de evento: la invoca un flujo con *Execute Agent* del conector Microsoft Copilot Studio ([Call Copilot Studio agents from Power Automate](https://learn.microsoft.com/power-automate/call-copilot-studio-agent#call-a-standard-harness-agent-from-a-cloud-flow)). Aun así, las herramientas y el conocimiento corren sin usuario, con las conexiones del dueño.

**Qué hacer.**

1. **Cuenta de servicio dedicada** (`agente-dsa` en este repositorio), dueña del agente, de los flujos y de sus conexiones. **Sin roles de directorio** y nunca la cuenta de un administrador (constitución, artículo 4).
2. **Permisos mínimos sobre los datos.** Como la cuenta "presta" sus permisos al agente, solo tiene lectura en la biblioteca `Protocolos`, edición en la lista `Eventos de seguridad` y membresía en el equipo del centro de operaciones. Nada más en SharePoint ni en Teams.
3. **Licencia que permita publicar.** Licencia de usuario de Copilot Studio con créditos en el entorno, o Microsoft 365 Copilot. Las licencias de prueba no habilitan la publicación ([FAQ de facturación](https://learn.microsoft.com/microsoft-copilot-studio/faq-billing-licensing)).
4. **Buzón de Exchange.** La página *Activity* pide licencia de Exchange y buzón, y por defecto solo muestra las interacciones en las que el agente usó **tus** credenciales ([Review agent activity](https://learn.microsoft.com/microsoft-copilot-studio/authoring-review-activity#historical-activity)). Sin buzón en la cuenta de servicio, nadie ve el historial del agente (ver §6).
5. **Probar qué ve el agente.** Learn recomienda revisar qué sistemas con autenticación usa el agente y probar qué sale por las acciones ([Data protection best practices](https://learn.microsoft.com/microsoft-copilot-studio/authoring-triggers-about#data-protection-best-practices)).

**Identidades de Azure.** La Function usa una identidad administrada asignada por el usuario, sin secretos. En Graph solo tiene `Sites.Selected` con rol `write` sobre el sitio de la demo ([Overview of Selected permissions](https://learn.microsoft.com/graph/permissions-selected-overview)). El inventario completo está en [ADR-007](adr/ADR-007-identidad-y-permisos.md). Para producción, Learn ofrece `Lists.SelectedOperations.Selected`, que limita el acceso a una sola lista; queda en la lista de verificación (§10).

> **Riesgo R-G1.** Learn documenta las credenciales del creador para disparadores y acciones de agentes autónomos, pero no documenta con qué identidad se consulta el conocimiento de SharePoint cuando el agente se ejecuta con *Execute Agent*. Se cierra con la prueba de R-17 (T-036). Plan B: la herramienta `LeerProtocolo`, con la conexión de la cuenta de servicio.

## 3. Entorno de Power Platform dedicado

**Qué hacer.**

- **Un entorno propio para operaciones de seguridad**, de tipo Sandbox o Producción, nunca *Trial* ni el predeterminado. El entorno es la frontera de seguridad de Power Platform. Fuera del entorno predeterminado, tener licencia no basta para entrar ([Environment access](https://learn.microsoft.com/power-platform/guidance/adoption/conditional-access#environment-access)).
- **Grupo de seguridad** asignado al entorno, para que solo entren el dueño, la cuenta de servicio y los administradores. Learn no lo permite en el entorno predeterminado ([Control user access](https://learn.microsoft.com/power-platform/admin/control-user-access)).
- **Auditoría de Dataverse** activada, con una retención acorde a la política de la organización ([Manage Dataverse auditing](https://learn.microsoft.com/power-platform/admin/manage-dataverse-auditing#configure-auditing-for-an-environment)).
- **Uso compartido de flujos de solución activado**, porque los disparadores de agente lo exigen ([Event trigger overview: solution-aware cloud flow sharing](https://learn.microsoft.com/microsoft-copilot-studio/authoring-triggers-about#solution-aware-cloud-flow-sharing-must-be-turned-on)).
- **Todo dentro de una solución** (`DelSensorAlAgente`), con paso controlado de desarrollo a prueba y a producción ([Secure your Copilot Studio projects](https://learn.microsoft.com/microsoft-copilot-studio/guidance/sec-gov-phase3)).

Por qué no el entorno predeterminado: todos los usuarios con licencia pueden crear en él, y una DLP que proteja el agente afectaría a todos los creadores del tenant ([Secure the default environment](https://learn.microsoft.com/power-platform/guidance/adoption/secure-default-environment)).

## 4. Políticas de datos (DLP) para disparadores y conectores

Copilot Studio aplica las políticas de datos en tiempo real, sin excepciones por agente ([Configure data policies for agents](https://learn.microsoft.com/microsoft-copilot-studio/admin-data-loss-prevention)). Los conectores de una misma solución deben estar en el mismo grupo de datos; si no, no pueden compartir datos.

### 4.1 Conectores que usa la solución

| Conector (nombre en el Power Platform admin center) | Para qué | Entorno dedicado | Resto del tenant | Referencia |
| --- | --- | --- | --- | --- |
| **Microsoft Copilot Studio** | Acción *Execute Agent* del flujo `DisparoAgente`. El mismo conector, bloqueado, impide los **disparadores de evento** y las evaluaciones automáticas con cuentas autenticadas | Business | **Blocked**, salvo en los entornos aprobados para agentes autónomos | [Block event triggers](https://learn.microsoft.com/microsoft-copilot-studio/admin-data-loss-prevention#block-event-triggers) |
| **When an HTTP request is received** | Disparador del flujo `DisparoAgente` | Business | Non-Business o Blocked; Learn advierte que la clasificación de los conectores HTTP afecta a los flujos secundarios | [Connector classification](https://learn.microsoft.com/power-platform/admin/dlp-connector-classification) |
| **Knowledge source with SharePoint and OneDrive in Copilot Studio** | Conocimiento: biblioteca `Protocolos` | Business | Según la política del tenant | [Knowledge source types and data policies](https://learn.microsoft.com/microsoft-copilot-studio/knowledge-add-unstructured-data#knowledge-source-types-and-data-policies) |
| **SharePoint** | Herramientas `LeerIncidente` y `PublicarIncidente` (leer y escribir la lista) | Business | Según la política del tenant | Ídem |
| **Microsoft Teams** | Publicar la tarjeta y esperar la respuesta | Business | Según la política del tenant | [Teams connector](https://learn.microsoft.com/connectors/teams/#known-issues-and-limitations-with-actions) |
| **Office 365 Users** | Obtener el UPN de quien respondió | Business | Según la política del tenant | [Overview of adaptive cards](https://learn.microsoft.com/power-automate/overview-adaptive-cards#known-issues) |

### 4.2 Conectores que se bloquean en el entorno dedicado

La solución no los necesita. Bloquearlos reduce la superficie de exfiltración ([Configure data policies for agents: connector names](https://learn.microsoft.com/microsoft-copilot-studio/admin-data-loss-prevention#connector-names-in-the-power-platform-admin-center)):

- **HTTP** (nodo de solicitud HTTP del agente). El agente no llama a ningún servicio externo.
- **Chat without Microsoft Entra ID authentication in Copilot Studio**. Así ningún agente del entorno se publica sin autenticación.
- **Direct Line channels**, **Facebook channel**, **WhatsApp channel**, **Omnichannel** y **SharePoint channel in Copilot Studio**. El agente no conversa por ningún canal: lo dispara un flujo.
- **Skills with Copilot Studio**.
- **Knowledge source with documents in Copilot Studio**. Los protocolos viven en SharePoint, no en archivos subidos al agente.
- Todo conector que no esté en la tabla 4.1. El grupo por defecto para conectores nuevos sigue siendo **Non-Business**, como recomienda Learn ([Default data group for new connectors](https://learn.microsoft.com/power-platform/admin/dlp-connector-classification#default-data-group-for-new-connectors)).

> **Riesgo R-G2.** Learn usa el nombre **Microsoft Copilot Studio** tanto para la entrada de la política que bloquea los disparadores de evento como para el conector de Power Automate que ofrece *Execute Agent*, pero no dice de forma explícita que se trate de la misma entrada. Si lo es, bloquearlo en el entorno dedicado rompe `DisparoAgente`. Prueba: en un entorno de prueba, bloquear el conector y comprobar si el flujo falla con un error de política de datos.
>
> **Riesgo R-G3.** Learn dice que las cargas desde SharePoint las gobierna **Knowledge source with SharePoint and OneDrive in Copilot Studio**, pero en la misma página pide bloquear el conector **SharePoint** para impedirlas. Antes de producción hay que comprobar cuál de los dos manda sobre el conocimiento ya configurado. Mientras tanto, los dos se clasifican como Business en el entorno dedicado.

## 5. Datos en el payload

**Qué dice Learn.** Lo que llega en el payload de un disparador puede salir a otros lugares por las acciones del agente ([Data protection for agents with triggers](https://learn.microsoft.com/microsoft-copilot-studio/authoring-triggers-about#data-protection-for-agents-with-triggers)). El historial de ejecución de un flujo guarda las entradas y salidas de cada paso durante 28 días ([Missing runs or triggers history](https://learn.microsoft.com/troubleshoot/power-platform/power-automate/flow-run-issues/missing-runs-or-triggers-history-for-a-flow)).

**Cómo lo limita el diseño.**

| Tramo | Qué viaja | Qué no viaja nunca |
| --- | --- | --- |
| Dispositivo → IoT Hub | `eventId`, `deviceId`, `type`, `zone`, `timestamp`, `rawSeverity`, `schemaVersion`. El esquema usa `additionalProperties: false` y no tiene ningún campo de texto libre | Nombres, correos, imágenes, video, matrículas |
| Function → flujo `DisparoAgente` | Solo `{"eventId": "..."}` ([ADR-003](adr/ADR-003-disparo-del-agente.md)) | Cualquier dato del incidente: el agente lo lee de la lista |
| Agente → `PublicarIncidente` | Severidad propuesta, justificación, resumen, pasos del protocolo, nombre del protocolo | Datos de personas: el agente no tiene ninguna fuente de donde sacarlos |
| Respuesta de la tarjeta → lista | Decisión, `DecididoPor` (UPN del supervisor), fecha y observación opcional | — |

Lo que queda en manos del operador:

- **`DecididoPor` y `Observacion` son datos personales** del supervisor. Son necesarios por el artículo 1 (quién decidió), así que se protegen en lugar de eliminarse: activar **Secure inputs** y **Secure outputs** en *Get user profile (V2)* y en la acción que escribe la decisión, para que no aparezcan en el historial ([Use secure inputs and secure outputs](https://learn.microsoft.com/power-automate/guidance/coding-guidelines/use-secure-inputs-outputs-triggers#use-secure-inputs-and-secure-outputs)).
- **El campo `Observacion` es texto libre.** La tarjeta indica que no se escriban nombres de terceros. La lista no puede impedirlo técnicamente, así que es una regla de operación y de formación.
- **Retención del historial.** En los flujos de solución, el administrador puede bajar la retención de 28 a 14 o a 7 días ([Manage cloud flow run history in Dataverse](https://learn.microsoft.com/power-automate/dataverse/cloud-flow-run-metadata#set-flowrun-time-to-live-in-power-platform-admin-center)).
- **Registros de la Function.** Solo llevan identificadores (`eventId`, `deviceId`, `type`) y tiempos. Learn advierte que el nivel `Trace` puede incluir datos sensibles y que nunca debe activarse en producción ([Log levels and categories](https://learn.microsoft.com/azure/azure-functions/functions-monitoring#log-levels-and-categories)).

## 6. Monitoreo

| Dónde | Qué muestra | Quién lo ve | Referencia |
| --- | --- | --- | --- |
| Copilot Studio, página **Activity** | Cada ejecución del agente, aun sin usuario ("Automated"): pasos, herramientas, consultas al conocimiento, errores y duración | Por defecto, solo quien autenticó la ejecución (la cuenta de servicio). Para otros, el administrador debe activar que se compartan las transcripciones. Requiere buzón de Exchange, y los datos se guardan en la ubicación del buzón, bajo los términos de Microsoft 365 | [Review agent activity](https://learn.microsoft.com/microsoft-copilot-studio/authoring-review-activity#historical-activity) |
| Copilot Studio, página **Monitor** | Resultados de las ejecuciones, uso de herramientas y de conocimiento, hasta 360 días; detalle de sesiones de los últimos 28 días | Dueño; otros con el rol *Analytics Viewer* (solo personas, no grupos) | [Monitor agent performance](https://learn.microsoft.com/microsoft-copilot-studio/analytics-overview), [Monitor autonomous agents](https://learn.microsoft.com/microsoft-copilot-studio/analytics-improve-agent-health) |
| **Historial de ejecuciones** de los flujos | Entrada y salida de cada paso de `DisparoAgente`, `LeerIncidente` y `PublicarIncidente` durante 28 días; en los flujos de agente, pestaña *Activity* | Dueños del flujo | [Monitor your agent flows](https://learn.microsoft.com/microsoft-copilot-studio/flow-manage-monitor), [Create a cloud flow: run history](https://learn.microsoft.com/power-automate/get-started-logic-flow#manage-a-cloud-flow) |
| **Application Insights** de la Function | Ejecuciones, excepciones, dependencias (Table, Graph, flujo) y los eventos con nombre del plan §7 (`EventRejected`, `IncidentDiscarded`, `AgentTriggerAuthFailed`, `EventFailed`…) | Roles de Azure sobre el recurso | [Monitor executions in Azure Functions](https://learn.microsoft.com/azure/azure-functions/functions-monitoring) |
| **Auditoría de Dataverse** | Cambios sobre las tablas del agente y accesos al entorno | Administradores; los registros de actividad van a Purview solo en entornos de producción | [Manage Dataverse auditing](https://learn.microsoft.com/power-platform/admin/manage-dataverse-auditing#configure-auditing-for-an-environment) |

Para producción, además: alertas de Azure Monitor sobre `EventFailed` y `AgentTriggerAuthFailed`, y una alerta sobre incidentes que siguen en `Nuevo` pasados 2 minutos, que indican que el agente no se disparó ([ADR-004](adr/ADR-004-puente-azure-m365.md)).

> **Riesgo R-G4.** Learn indica que el muestreo de Application Insights está activado por defecto en Azure Functions ([Application Insights pricing and limits](https://learn.microsoft.com/azure/azure-functions/functions-monitoring#application-insights-pricing-and-limits)). Si el muestreo descarta trazas, la medición del tramo 1 o una alerta pueden quedarse sin datos. Hay que excluir de la muestra los tipos que usan las consultas y las alertas, y comprobarlo en el ensayo.

## 7. Cuotas y créditos

**Cada ejecución cuesta créditos.** Las ejecuciones autónomas consumen Copilot Credits según la tabla oficial de tarifas ([Billing rates](https://learn.microsoft.com/microsoft-copilot-studio/requirements-messages-management#copilot-credits-billing-rates)). Por eso la Function deduplica en Azure **antes** de llegar al agente: una ráfaga de 20 eventos iguales crea un solo incidente, y nunca se crean más de 10 incidentes por minuto ([ADR-006](adr/ADR-006-deduplicacion.md)). La estimación por incidente (unos 15 créditos) y el presupuesto están en [ADR-001](adr/ADR-001-facturacion-creditos-copilot-studio.md); aquí no se repiten.

**Controles recomendados (ADR-001).**

1. **Pago por uso** con un plan de facturación vinculado solo al entorno dedicado, en un grupo de recursos aparte, con presupuesto y alertas al 50 %, 80 % y 100 % ([Set up pay-as-you-go](https://learn.microsoft.com/power-platform/admin/pay-as-you-go-set-up#create-a-billing-plan)). El presupuesto avisa, pero no detiene el consumo.
2. **Límite mensual por agente** en *Licensing* → *Copilot Studio* → *Manage Agents*, con aviso y **parada automática** al llegar al límite ([Manage monthly consumption limits](https://learn.microsoft.com/power-platform/admin/manage-copilot-studio-copilot-credits-capacity#manage-monthly-consumption-limits-for-copilot-studio-agents)). No hay un límite por defecto para todo el tenant: hay que fijarlo agente por agente ([Govern Copilot Credit consumption](https://learn.microsoft.com/microsoft-copilot-studio/guidance/govern-credit-consumption#choose-controls-based-on-environment-purpose)).
3. **Créditos asignados al entorno** para los flujos del agente. Learn aclara dos puntos del límite por agente: **no detiene los flujos del agente**, que se cobran y se controlan aparte, y **no actúa al instante**, así que el agente puede seguir respondiendo un tiempo después de llegar al límite ([Manage capacity, nota](https://learn.microsoft.com/power-platform/admin/manage-copilot-studio-copilot-credits-capacity#manage-capacity)). Por eso el límite se fija con margen, y el freno de los flujos es la capacidad del entorno.

**Cuotas de servicio.** Los mensajes de IA generativa (orquestación, acciones, flujos del agente y respuestas con conocimiento) tienen una cuota **por entorno de Dataverse**: 100 RPM / 2 000 RPH con pago por uso y 10 RPM / 200 RPH en entornos de prueba o de desarrollador ([Quotas and limits](https://learn.microsoft.com/microsoft-copilot-studio/requirements-quotas#generative-ai-messages-to-an-agent)). La cuota la comparten todos los agentes del entorno, otra razón para tener un entorno dedicado. El conector de Teams limita el *Flow bot* a 25 operaciones que no son GET por conexión cada 300 s ([Teams connector: throttling](https://learn.microsoft.com/connectors/teams/#throttling-limits)), y con eso se dimensiona el límite de 10 incidentes por minuto ([ADR-008](adr/ADR-008-publicacion-tarjeta-y-decision.md)).

> **Riesgo R-G5.** Learn no dice cuántos mensajes de IA generativa consume un incidente (orquestación más dos herramientas más una consulta al conocimiento). Con 10 RPM, un minuto con el máximo de 10 incidentes podría pasar la cuota. Se mide en el ensayo con el informe de consumo y la página *Monitor*. Si se pasa, se baja `MAX_INCIDENTS_PER_MINUTE` o se pasa a un entorno con pago por uso.

## 8. Deuda consciente: la cadena de conexión de IoT Hub

**Qué hay en la demo.** El disparador de IoT Hub de Azure Functions **no admite conexiones con identidad** ([IoT Hub trigger: connections](https://learn.microsoft.com/azure/azure-functions/functions-bindings-event-iot-trigger#connections)), y el endpoint integrado solo se lee con clave de acceso compartido ([Control access to IoT Hub with Microsoft Entra ID](https://learn.microsoft.com/azure/iot-hub/authenticate-authorize-azure-ad#permissions-for-iot-hub-service-apis)). Por eso la solución guarda **una** cadena de conexión:

- con una política dedicada `func-reader`, que solo tiene `ServiceConnect` (nunca `iothubowner`) ([IoT hub-level shared access policies](https://learn.microsoft.com/azure/iot-hub/authenticate-authorize-sas#access-control-and-permissions));
- como secreto en Key Vault, que la app lee mediante una referencia con la identidad administrada, sin que aparezca en ninguna salida del despliegue ([Key Vault references](https://learn.microsoft.com/azure/app-service/app-service-key-vault-references#access-vaults-with-a-user-assigned-identity));
- con un script de rotación que regenera la clave y fuerza la recarga de la referencia ([Understand rotation](https://learn.microsoft.com/azure/app-service/app-service-key-vault-references#understand-rotation)).

Detalle completo en [ADR-005](adr/ADR-005-hosting-function.md) §3.

**Alternativa de producción: identidad de punta a punta.**

1. Crear un espacio de nombres de **Event Hubs** con un event hub para los eventos.
2. Darle a la identidad administrada de **IoT Hub** el rol *Azure Event Hubs Data Sender* sobre ese event hub y crear un endpoint personalizado de enrutamiento con autenticación por identidad ([Configure message routing with managed identities](https://learn.microsoft.com/azure/iot-hub/iot-hub-managed-identity#configure-message-routing-with-managed-identities)).
3. Cambiar la Function al **disparador de Event Hubs** con conexión por identidad (`<prefijo>__fullyQualifiedNamespace` + `__credential` + `__clientId`) y darle a `id-dsa-func` el rol *Azure Event Hubs Data Receiver* ([Event Hubs trigger: connections](https://learn.microsoft.com/azure/azure-functions/functions-bindings-event-hubs-trigger#connections), [Manage connections: identity](https://learn.microsoft.com/azure/azure-functions/manage-connections#define-connections)).
4. Borrar la política `func-reader`, el secreto de Key Vault y el script de rotación.

Learn recomienda este camino cuando se necesita identidad administrada de punta a punta ([IoT Hub trigger: connections, nota](https://learn.microsoft.com/azure/azure-functions/functions-bindings-event-iot-trigger#connections)). Un IoT Hub gratuito (F1) admite un solo endpoint personalizado, que alcanza para esta ruta ([Microsoft.Devices IotHubs: RoutingProperties](https://learn.microsoft.com/azure/templates/microsoft.devices/2026-05-01-preview/iothubs#property-values)).

**Costo.** Una unidad de procesamiento Basic de Event Hubs cuesta unos **USD 11 al mes** (USD 0,015 por hora en `eastus2`). El precio sale de la [página de precios de Event Hubs](https://azure.microsoft.com/pricing/details/event-hubs/), no de Learn, y se vuelve a consultar antes de desplegar. En la demo sería más de la mitad del presupuesto de USD 20 al mes en Azure (constitución, artículo 9). En producción, el costo fijo es menor que el de operar y rotar un secreto.

## 9. Restricción del disparador HTTP a identidades específicas

El flujo `DisparoAgente` es la única puerta de entrada al agente. Learn recomienda exigir un token de Microsoft Entra ID en el disparador *When an HTTP request is received* y limitarlo a usuarios o entidades de servicio concretos del tenant ([Secure the HTTP request trigger](https://learn.microsoft.com/power-automate/guidance/coding-guidelines/use-secure-inputs-outputs-triggers#secure-the-http-request-trigger)).

Configuración ([ADR-003](adr/ADR-003-disparo-del-agente.md), [ADR-007](adr/ADR-007-identidad-y-permisos.md)):

- **Who can trigger the flow** = *Specific users in my tenant*, con el **object ID** de la identidad administrada de la Function. Learn admite object IDs de entidades de servicio y valida `aud`, `iss`, `tid` y `oid` ([OAuth authentication for HTTP request triggers](https://learn.microsoft.com/power-automate/oauth-authentication)).
- **Audiencia exacta** `https://service.flow.microsoft.com/`, con la barra final ([Audience values](https://learn.microsoft.com/power-automate/oauth-authentication#audience-values)). Con identidad administrada, el alcance `.default` lleva doble barra ([Trailing slash and .default](https://learn.microsoft.com/entra/identity-platform/scopes-oidc#trailing-slash-and-default)).
- **Nunca** *Any user in my tenant* ni la URL con firma (SAS) sin autenticación: cualquier cuenta del tenant, o cualquiera que tenga la URL, podría disparar al agente y consumir créditos.
- **Segunda entrada solo para operación.** La cuenta del operador figura como segunda identidad autorizada, solo para reintentar un incidente que quedó en `Nuevo`. En producción, esa entrada se sustituye por un procedimiento con aprobación o se revisa cada mes.
- **Mensaje mínimo.** El cuerpo solo lleva el `eventId`; el flujo no acepta otros campos.

> **Riesgo R-G6 (R-13 en el plan).** Learn no documenta que Power Automate acepte el token de una **identidad administrada** en este disparador. La prueba es T-025. Si falla, la alternativa sin secretos es un registro de aplicación con una credencial federada que confía en la identidad administrada ([Configure an application to trust a managed identity](https://learn.microsoft.com/entra/workload-id/workload-identity-federation-config-app-trust-managed-identity)).

## 10. Lista de verificación: de demo a producción

1. **Entorno dedicado** de Sandbox o Producción con grupo de seguridad, auditoría de Dataverse, uso compartido de flujos de solución y la solución `DelSensorAlAgente` desplegada como administrada (§3).
2. **DLP propia del entorno**, con los seis conectores de §4.1 en Business y los de §4.2 bloqueados; en el resto del tenant, **Microsoft Copilot Studio** y **When an HTTP request is received** bloqueados. Cerrar R-G2 y R-G3 antes de aplicarla.
3. **Cuenta de servicio** sin roles de directorio, con licencia de usuario de Copilot Studio y buzón de Exchange, y con permisos de SharePoint limitados a leer `Protocolos` y editar la lista (§2).
4. **Disparador HTTP** limitado al object ID de la identidad de la Function, sin entrada permanente para personas (§9).
5. **Ruta IoT Hub → Event Hubs con identidad administrada**, sin cadena de conexión ni secreto en Key Vault; costo de unos USD 11 al mes aprobado (§8).
6. **Graph**: `Sites.Selected` solo sobre el sitio de operaciones, y evaluar `Lists.SelectedOperations.Selected` para limitarlo a la lista ([ADR-007](adr/ADR-007-identidad-y-permisos.md)).
7. **Datos**: *Secure inputs/outputs* en las acciones que manejan `DecididoPor` y `Observacion`, retención del historial de flujos definida y nivel de registro de la Function en *Information* o superior (§5).
8. **Créditos**: pago por uso con presupuesto propio, límite por agente con parada automática y capacidad asignada al entorno para los flujos (§7).
9. **Monitoreo**: *Activity* compartido con quien audita, rol *Analytics Viewer* en *Monitor*, alertas sobre `EventFailed`, `AgentTriggerAuthFailed` e incidentes en `Nuevo`, y una cola de mensajes fallidos para los eventos que agotan los reintentos (§6, [ADR-004](adr/ADR-004-puente-azure-m365.md)).
10. **Artículo 1 vigilado**: revisión de seguridad obligatoria para todo cambio en las instrucciones, las tarjetas o los flujos, y una prueba que confirme que ningún flujo tiene acciones de correo, llamada ni mensaje fuera del canal (§1).

## 11. Desviaciones de la demo en vivo

La demo de la sesión no cumple todos los puntos de esta guía: hay diferencias de tenant, de entorno, de DLP, de licencias y de facturación. Las diferencias, sus riesgos y sus mitigaciones están **solo** en [ADR-002](adr/ADR-002-entorno-demo-en-vivo.md). `demo/preflight` muestra en amarillo el entorno que no es dedicado y remite a ese ADR. Lo que cambia en el código de la demo (la cadena de IoT Hub de §8 y la segunda entrada del disparador de §9) está descrito en esta guía como deuda, con su alternativa.

## Riesgos registrados en esta guía

| ID | Riesgo | Cómo se cierra |
| --- | --- | --- |
| R-G1 | Identidad con la que se consulta el conocimiento de SharePoint con *Execute Agent* | Prueba de R-17 (T-036) |
| R-G2 | Si bloquear "Microsoft Copilot Studio" en la DLP también bloquea *Execute Agent* en los flujos | Prueba en un entorno de prueba con la política aplicada |
| R-G3 | Qué conector de la DLP gobierna el conocimiento de SharePoint ya configurado | Misma prueba, bloqueando uno y luego el otro |
| R-G4 | El muestreo de Application Insights descarta trazas que usan la medición o las alertas | Revisar `excludedTypes` y comparar los conteos en el ensayo |
| R-G5 | Consumo de la cuota de IA generativa por incidente frente a 10 RPM en entornos de prueba | Medir en el ensayo con *Monitor* y el informe de consumo |
| R-G6 | Token de identidad administrada en el disparador HTTP (R-13 del plan) | T-025 |
