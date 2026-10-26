# Guía de configuración del Agente de Operaciones

Tarea T-042 · HU-08 · CA-08.3, CA-08.4, CA-06.4

Esta guía lleva desde un entorno vacío hasta el agente publicado, con sus tres flujos y la tarjeta en Teams. Parte de la **configuración recomendada** (§8.1 de la especificación). Las diferencias de la demo en vivo están en [ADR-002](../docs/adr/ADR-002-entorno-demo-en-vivo.md) y en el apartado [Si no tienes capacidad para un Sandbox](#si-no-tienes-capacidad-para-un-sandbox).

La guía no contiene identificadores del tenant: donde hace falta uno, aparece entre `<...>`.

## Qué vas a construir

| Pieza | Qué hace | Dueño |
| --- | --- | --- |
| Solución `DelSensorAlAgente` | Contiene el agente, los tres flujos, las referencias de conexión y las variables de entorno | `agente-dsa` |
| Agente "Agente de Operaciones" | Lee el incidente, consulta el protocolo, propone la severidad y publica la propuesta. Nunca decide ni contacta a nadie (Art. 1) | `agente-dsa` |
| `DisparoAgente` | Flujo con disparador HTTP protegido con Microsoft Entra ID: recibe `{eventId}` desde la Function y ejecuta el agente | `agente-dsa` |
| `LeerIncidente` | Herramienta del agente: lee el elemento de la lista por `EventId` | `agente-dsa` |
| `PublicarIncidente` | Herramienta del agente: registra la propuesta, publica la tarjeta en el canal y espera la decisión del supervisor ([ADR-008](../docs/adr/ADR-008-publicacion-tarjeta-y-decision.md)) | `agente-dsa` |

## Requisitos

- Lista `Eventos de seguridad` y biblioteca `Protocolos` creadas con `sharepoint/provision.ps1` (T-029). La biblioteca tiene un documento por tipo de evento.
- Un equipo de Teams con los canales `Centro de operaciones` (demo) y `Pruebas spike` (pruebas).
- La infraestructura de Azure desplegada con `infra/deploy.ps1` y el permiso `Sites.Selected` concedido ([admin-sites-selected.md](../docs/admin-sites-selected.md)).

## Paso 1. Entorno de Power Platform

**Recomendado:** un entorno **Sandbox** dedicado (`DSA-Demo`) con Dataverse, nunca de tipo *Trial*, porque se elimina con sus agentes a los 30 días y no admite pago por uso.

1. Crea el entorno con base de datos ([Create an environment](https://learn.microsoft.com/power-platform/admin/create-environment#create-an-environment-with-a-database)).
2. Asígnale un grupo de seguridad para limitar quién entra ([Control user access](https://learn.microsoft.com/power-platform/admin/control-user-access)).
3. Crea una política de datos propia para el entorno. La tabla de conectores y su clasificación está en [docs/gobernanza.md](../docs/gobernanza.md) ([Configure data policies for agents](https://learn.microsoft.com/microsoft-copilot-studio/admin-data-loss-prevention)).
4. Activa la auditoría de Dataverse ([Manage Dataverse auditing](https://learn.microsoft.com/power-platform/admin/manage-dataverse-auditing#configure-auditing-for-an-environment)).
5. Activa *solution-aware cloud flow sharing*, que necesitan los flujos de una solución que usa un agente ([Event trigger overview: solution-aware cloud flow sharing](https://learn.microsoft.com/microsoft-copilot-studio/authoring-triggers-about#solution-aware-cloud-flow-sharing-must-be-turned-on)).
6. Vincula el pago por uso con un presupuesto propio y fija el límite mensual del agente: 3 000 créditos en esta demo ([Set up pay-as-you-go](https://learn.microsoft.com/power-platform/admin/pay-as-you-go-set-up#create-a-billing-plan), [Manage monthly consumption limits](https://learn.microsoft.com/power-platform/admin/manage-copilot-studio-copilot-credits-capacity#manage-monthly-consumption-limits-for-copilot-studio-agents)). La estimación por incidente está en [ADR-001](../docs/adr/ADR-001-facturacion-creditos-copilot-studio.md).

## Paso 2. Cuenta de servicio `agente-dsa`

1. Crea una cuenta sin privilegios de administración y asígnale una licencia de Copilot Studio. Business Premium sola no basta para la orquestación generativa ([Copilot Studio licensing](https://learn.microsoft.com/microsoft-copilot-studio/billing-licensing#get-access-to-copilot-studio)).
2. Agrégala como miembro del equipo de Teams. La tarjeta se publica como *Flow bot* en el canal, pero la conexión de Teams es de esta cuenta.
3. Dale permiso de **lectura y escritura** en el sitio de la demo y de **lectura** en la biblioteca `Protocolos`. El conocimiento de SharePoint solo muestra lo que puede leer la identidad que ejecuta al agente ([Add SharePoint as a knowledge source](https://learn.microsoft.com/microsoft-copilot-studio/knowledge-add-sharepoint)).
4. Todo lo que sigue (solución, conexiones, agente y flujos) se crea **iniciando sesión como `agente-dsa`**. Un agente con disparadores usa las credenciales de su creador en las acciones ([Data protection for agents with triggers](https://learn.microsoft.com/microsoft-copilot-studio/authoring-triggers-about#data-protection-for-agents-with-triggers)).

## Paso 3. Solución, conexiones y variables de entorno

1. Crea el publicador `dsa` y la solución `DelSensorAlAgente`, y márcala como solución preferida para que todo lo nuevo entre en ella ([Create a solution](https://learn.microsoft.com/power-apps/maker/data-platform/create-solution)).
2. Crea dos referencias de conexión, una de SharePoint y una de Microsoft Teams, cada una con una conexión de `agente-dsa` ([Use a connection reference in a solution](https://learn.microsoft.com/power-apps/maker/data-platform/create-connection-reference#manually-add-a-connection-reference-using-solution-explorer)).
3. Crea las variables de entorno `dsa_TimeoutDecision` (`PT15M`) y `dsa_SitioDemo` (URL del sitio) ([Environment variables overview](https://learn.microsoft.com/power-apps/maker/data-platform/environmentvariables)).

## Paso 4. El agente

1. En Copilot Studio, crea un agente del **standard harness** llamado "Agente de Operaciones" ([Access standard harness agents](https://learn.microsoft.com/microsoft-copilot-studio/agents-experience/switch-experiences), [Harnesses](https://learn.microsoft.com/microsoft-copilot-studio/harnesses-overview)).
2. Elige **inglés (en-US)** como idioma principal. No se puede cambiar después ([Language support](https://learn.microsoft.com/microsoft-copilot-studio/authoring-language-support)). Las instrucciones ordenan responder en español; es el hallazgo 1 del spike ([ADR-003](../docs/adr/ADR-003-disparo-del-agente.md)).
3. Deja activada la **orquestación generativa**.
4. Pega en *Instructions* el bloque entre `<!-- INSTRUCCIONES: inicio -->` y `<!-- INSTRUCCIONES: fin -->` de [instrucciones.md](instrucciones.md) ([Create an agent — edit the instructions](https://learn.microsoft.com/microsoft-copilot-studio/authoring-first-bot#create-an-agent)).
5. En *Knowledge*, agrega la biblioteca `Protocolos` con la opción **SharePoint** de la sección destacada, la que usa el conector completo, y escribe una descripción que diga para qué sirve ("Protocolos de respuesta por tipo de evento de seguridad física") ([Add SharePoint as a knowledge source](https://learn.microsoft.com/microsoft-copilot-studio/knowledge-add-sharepoint#add-sharepoint-sites-as-a-knowledge-source)).
6. Desactiva el conocimiento general y la búsqueda web, para que el agente responda solo con los protocolos ([Filter your SharePoint source — more settings](https://learn.microsoft.com/microsoft-copilot-studio/knowledge-add-sharepoint#filter-your-sharepoint-source)).

## Paso 5. Herramienta `LeerIncidente` (flujo del agente, modo rápido)

1. En el agente, *Tools* → *Add a tool* → *New agent flow* ([Create an agent flow as a tool](https://learn.microsoft.com/microsoft-copilot-studio/advanced-flow-create), [Add an agent flow as a tool](https://learn.microsoft.com/microsoft-copilot-studio/flow-agent)).
2. Disparador *When an agent calls the flow* con una entrada de texto `eventId` y la descripción "Identificador UUID del incidente, tal como llega en el mensaje Nuevo incidente".
3. Acción de SharePoint *Send an HTTP request to SharePoint*, renombrada `LeerElemento`, con método `GET` y esta URI (encabezado `Accept: application/json;odata=nometadata`):

   ```text
   _api/web/lists/getbytitle('Eventos de seguridad')/items?$select=EventId,TipoEvento,Zona,NombreZona,Sitio,SeveridadInicial,Repeticiones,FechaEventoUtc,Estado&$filter=EventId eq '<eventId>'&$top=1
   ```

4. *Respond to the agent* con una salida de texto `incidente` que incluya los campos y `HoraLocal` en formato `HH:mm COT`, calculada con `convertFromUtc(..., 'SA Pacific Standard Time', 'HH:mm')` ([convertFromUtc](https://learn.microsoft.com/azure/logic-apps/workflow-definition-language-functions-reference#convertFromUtc)).
5. Activa el **modo rápido**: este flujo no espera nada y así responde en pocos segundos ([Express mode — limitations](https://learn.microsoft.com/microsoft-copilot-studio/agent-flow-express-mode#limitations)).
6. **Guarda el borrador antes de publicar.** Una expresión agregada a una salida de *Respond to the agent* se pierde si publicas sin guardar el borrador; revisa las salidas en el historial de la primera ejecución.

## Paso 6. Herramienta `PublicarIncidente` (flujo del agente, sin modo rápido)

Este flujo **no** puede ir en modo rápido: espera hasta 15 minutos la respuesta de la tarjeta, y el modo rápido no admite esperas ([Express mode — limitations](https://learn.microsoft.com/microsoft-copilot-studio/agent-flow-express-mode#limitations)). Su diseño está en [ADR-008](../docs/adr/ADR-008-publicacion-tarjeta-y-decision.md).

La definición se genera desde las tarjetas versionadas en `cards/`, con los identificadores del tenant como parámetros:

```powershell
python -m agent.flows.build_publicar_incidente --site-url <url del sitio> --team-id <groupId del equipo> `
    --channel-id <id del canal> --sharepoint-reference <nombre lógico de la referencia de SharePoint> `
    --teams-reference <nombre lógico de la referencia de Teams> --out <archivo fuera del repositorio>
```

El archivo resultante es el `clientdata` del flujo. Hay dos formas de crearlo:

- **Con la API de Dataverse** ([Work with cloud flows using code](https://learn.microsoft.com/power-automate/manage-flows-with-code#create-a-cloud-flow)): `POST` a `workflows` con `category = 5`, `type = 1`, `primaryentity = none`, `name = PublicarIncidente`, el `clientdata` y el encabezado `MSCRM.SolutionUniqueName: DelSensorAlAgente`. El flujo queda en borrador (`statecode = 0`).
- **En el diseñador**, siguiendo la misma estructura: leer, comprobar el estado `Nuevo`, limitar la severidad a un nivel, actualizar a `Pendiente de decisión`, responder al agente, publicar la tarjeta y esperar, y las ramas de decisión y de vencimiento.

Reglas que salen de la integración (`specs/04-verificacion.md`):

1. **El dueño del flujo y de las conexiones debe ser la misma cuenta.** Con otra cuenta, actualizar o activar el flujo falla con `ConnectionAuthorizationFailed`. Si lo creas con la API desde una cuenta de administrador, asígnale `agente-dsa` como dueño en la misma petición (`ownerid@odata.bind`) y actívalo con la sesión de `agente-dsa` (`statecode = 1`).
2. **Ninguna expresión puede pasar de 8 192 caracteres** ([Limits and configuration — flow definition limits](https://learn.microsoft.com/power-automate/limits-and-config#flow-definition-limits)). Por eso la plantilla de la tarjeta va como objeto en su propio *Compose* y los valores escapados en otro.
3. **La espera vencida cuenta como falla.** Al final de la rama de vencimiento, una acción *Terminate* con estado `Succeeded` deja la ejecución en verde ([Terminate action](https://learn.microsoft.com/azure/logic-apps/logic-apps-workflow-actions-triggers#terminate-action)).
4. **Si el diseñador tiene un borrador sin publicar, la API rechaza la actualización** (`0x80040203`). Publica primero desde el diseñador. Si el botón *Publish* no se activa porque no hay cambios, haz un cambio neutro, por ejemplo agregar y borrar un espacio en la descripción de una entrada, y publica sin guardar antes.
5. La tarjeta se publica con *Post adaptive card and wait for a response*, como *Flow bot* en el canal y con `limit.timeout = PT15M` ([Teams connector — Post adaptive card and wait for a response](https://learn.microsoft.com/connectors/teams/#post-adaptive-card-and-wait-for-a-response)). En las notificaciones y en la vista previa del canal, Teams muestra "Card - access it on go.skype.com/cards.unsupported"; en el canal la tarjeta se ve completa.

## Paso 7. Agregar las herramientas al agente

1. En *Tools* → *Add a tool* → *Agent flow*, elige `LeerIncidente` y `PublicarIncidente` ([Add an agent flow as a tool](https://learn.microsoft.com/microsoft-copilot-studio/flow-agent)).
2. En `PublicarIncidente`, usa *Agregar entrada* para incluir también `pasosProtocolo` y `protocoloAplicado`: son opcionales en el disparador y no aparecen solos. Las seis entradas se llenan con *Dynamically fill with AI*.
3. Escribe la descripción de cada herramienta: el orquestador la usa para decidir cuándo llamarla ([Authoring descriptions](https://learn.microsoft.com/microsoft-copilot-studio/advanced-generative-actions#authoring-descriptions)). La de `PublicarIncidente`:

   > Registra la propuesta del agente para un incidente en estado Nuevo y publica la tarjeta para que el supervisor decida en el canal de operaciones. Llamar una sola vez por incidente, después de LeerIncidente y de consultar el protocolo. Devuelve resultado "publicado" o "ya publicado". No ejecuta ninguna acción física ni contacta a nadie: solo la persona decide.

## Paso 8. `DisparoAgente` (flujo de nube)

1. Crea en la solución un flujo instantáneo con el disparador *When an HTTP request is received* y, en *Who can trigger the flow*, **Specific users in my tenant** con dos object IDs: el de la identidad administrada `id-dsa-func` y el de la cuenta del operador, que usan `demo/retrigger.ps1` y `demo/inject.ps1` ([OAuth authentication for HTTP request triggers](https://learn.microsoft.com/power-automate/oauth-authentication), [Secure the HTTP request trigger](https://learn.microsoft.com/power-automate/guidance/coding-guidelines/use-secure-inputs-outputs-triggers#secure-the-http-request-trigger)).
2. El cuerpo es solo `{"eventId": "..."}` ([ADR-003](../docs/adr/ADR-003-disparo-del-agente.md)).
3. Agrega la acción *Execute Agent* del conector de Copilot Studio (en la búsqueda aparece como *Power Virtual Agents*) con el agente "Agente de Operaciones" y el mensaje `Nuevo incidente <eventId>` ([Call Copilot Studio agents from Power Automate](https://learn.microsoft.com/power-automate/call-copilot-studio-agent#call-a-standard-harness-agent-from-a-cloud-flow)).
4. Responde `202` sin esperar al agente.
5. El token de la Function usa la audiencia `https://service.flow.microsoft.com/` ([Audience values](https://learn.microsoft.com/power-automate/oauth-authentication#audience-values)). Guarda la URL del disparador en la configuración de la Function (`DSA_FLOW_URL`), nunca en el repositorio.

## Paso 9. Publicar y probar

1. Publica el agente ([Key concepts — Publish and deploy your agent](https://learn.microsoft.com/microsoft-copilot-studio/publication-fundamentals-publish-channels)). Cada cambio en las instrucciones o en las herramientas exige volver a publicar.
2. Crea un incidente de prueba con `./demo/inject.ps1 -Type puerta_forzada -Zone Z-03 -EsPrueba`.
3. Comprueba en orden:
   - el historial de `DisparoAgente` (202);
   - la página *Activity* del agente: llamó a `LeerIncidente`, consultó el protocolo y llamó a `PublicarIncidente` ([Review agent activity](https://learn.microsoft.com/microsoft-copilot-studio/authoring-review-activity));
   - la lista: `Estado = Pendiente de decisión`;
   - la tarjeta en el canal;
   - al responder la tarjeta: `Estado`, `Decision`, `DecididoPor`, `FechaDecision` y `Observacion`, y la tarjeta de solo lectura.
4. Mide los tiempos con `./demo/measure.ps1 -Last 10`.

## Si no tienes capacidad para un Sandbox

Si el tenant no tiene capacidad de Dataverse para crear un entorno nuevo, la alternativa es el **entorno predeterminado**. Así se hizo la demo en vivo ([ADR-002](../docs/adr/ADR-002-entorno-demo-en-vivo.md)).

| Riesgo | Por qué | Mitigación |
| --- | --- | --- |
| No se puede limitar el acceso con un grupo de seguridad | Learn no lo permite en el entorno predeterminado ([Control user access](https://learn.microsoft.com/power-platform/admin/control-user-access)) | Solo `agente-dsa` es dueño de los componentes; nadie más tiene permisos sobre la solución |
| Una política de datos propia afectaría a toda la organización | El entorno lo usan todos los usuarios del tenant | Revisa la política del tenant contra la tabla de conectores de [docs/gobernanza.md](../docs/gobernanza.md) ([Secure the default environment](https://learn.microsoft.com/power-platform/guidance/adoption/secure-default-environment)) |
| Los componentes conviven con los de otras personas | Es un entorno compartido | Todo vive en la solución `DelSensorAlAgente`, con el publicador `dsa` |
| Los créditos salen de la capacidad del tenant | No hay un plan de pago por uso propio | Límite por agente y revisión del consumo en `demo/preflight` ([Manage Copilot Credits and capacity](https://learn.microsoft.com/power-platform/admin/manage-copilot-studio-copilot-credits-capacity)) |

`demo/preflight` muestra **amarillo** cuando el entorno es el predeterminado y remite a ADR-002.
