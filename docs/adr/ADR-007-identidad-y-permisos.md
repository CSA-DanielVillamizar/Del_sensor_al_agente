# ADR-007 — Identidades y permisos mínimos de la parte Azure

| Campo | Valor |
| --- | --- |
| Estado | Aceptado ("aprobado fase 2" de Daniel, 2026-10-26) |
| Fecha | 2026-10-09 |
| Decisiones relacionadas | DEC-02 ([ADR-004](ADR-004-puente-azure-m365.md)), DEC-03 ([ADR-005](ADR-005-hosting-function.md)), DEC-05 ([ADR-003](ADR-003-disparo-del-agente.md)) |
| Historias | HU-01 (CA-01.4), HU-04 (CA-04.4), HU-06 (CA-06.1, CA-06.2, CA-06.4), HU-14 (CA-14.2), Art. 4 |
| Responsables | arquitecto-cloud; revisión obligatoria: revisor-seguridad |

## Contexto

- Art. 4: identidades administradas, Key Vault, permisos mínimos, `Sites.Selected` solo sobre el sitio de la demo, cuenta de servicio dedicada para el agente.
- Las identidades administradas son entidades de servicio de un tipo especial y pueden pedir tokens para cualquier recurso que admita autenticación de Microsoft Entra ([How managed identities work](https://learn.microsoft.com/entra/identity/managed-identities-azure-resources/how-managed-identities-work-vm), [What are managed identities](https://learn.microsoft.com/entra/identity/managed-identities-azure-resources/overview)). Su *Principal ID* es el object ID de esa entidad de servicio ([Managed identities glossary](https://learn.microsoft.com/entra/identity/managed-identities-azure-resources/managed-identities-glossary)).
- Los permisos de Graph se asignan a una identidad administrada con un *app role assignment* por PowerShell o API, no desde el portal ([Grant API permissions to managed identities](https://learn.microsoft.com/powershell/entra-powershell/grant-api-permissions-managed-identity)).
- `Sites.Selected` necesita tres cosas: el consentimiento del alcance en Entra ID, el permiso sobre el recurso con `POST /sites/{siteId}/permissions` y un token que lleve el alcance. Para conceder permisos a nivel de sitio hace falta `Sites.FullControl.All` delegado y un rol de administrador como SharePoint Administrator ([Overview of Selected permissions](https://learn.microsoft.com/graph/permissions-selected-overview), [Create permission](https://learn.microsoft.com/graph/api/site-post-permissions)).
- El disparador HTTP de Power Automate con *Specific users in my tenant* admite **object IDs de entidades de servicio** y exige las notificaciones `aud` (exacta, con barra final: `https://service.flow.microsoft.com/`), `iss`, `tid` y `oid` ([OAuth authentication for HTTP request triggers](https://learn.microsoft.com/power-automate/oauth-authentication)). Si el recurso termina en barra, el alcance `.default` lleva doble barra: `https://service.flow.microsoft.com//.default` ([Trailing slash and .default](https://learn.microsoft.com/entra/identity-platform/scopes-oidc#trailing-slash-and-default)).

## Decisión

### 1. Inventario de identidades

| Identidad | Tipo | Para qué | Credencial |
| --- | --- | --- | --- |
| `id-dsa-func` | Identidad administrada **asignada por el usuario**, en el grupo de recursos de la demo | Todo lo que hace la Function: almacenamiento del host, Table, Key Vault, Application Insights, Graph y el flujo HTTP | Ninguna en manos de nadie (la gestiona Azure) |
| `sim-01`, `preflight-01` y, si HU-03 sigue, `pi-01` | Identidades de dispositivo en IoT Hub | Enviar mensajes dispositivo-nube | Clave simétrica por dispositivo, solo en `.env` local (CA-01.4). La Function marca `EsPrueba = Sí` cuando `iothub_metadata["connection-device-id"]` es `preflight-01`, un valor que pone IoT Hub y no el emisor |
| `agente-dsa` | Cuenta de servicio de Microsoft 365 (arquitecto-m365) | Dueña del agente y de los flujos | Sin permisos de Azure |
| Daniel (operador) | Usuario | Desplegar, dar de alta los dispositivos, `sharepoint/provision`, `demo/reset`, `demo/preflight`, `demo/retrigger`, `demo/inject`, `demo/measure` | Su sesión de `az` y de Graph; ningún secreto en archivos |

### 2. Permisos de `id-dsa-func`

| Recurso | Permiso | Ámbito | Cómo se otorga | Referencia |
| --- | --- | --- | --- | --- |
| Storage (host y despliegue) | *Storage Blob Data Owner* | Cuenta de la Function | Bicep (`Microsoft.Authorization/roleAssignments`) | [Grant permissions to an identity](https://learn.microsoft.com/azure/azure-functions/manage-connections#grant-permissions-to-an-identity) |
| Storage (tablas `dedup`, `ratelimit` y diagnóstico del host) | *Storage Table Data Contributor* | Cuenta de la Function | Bicep | Misma referencia |
| Key Vault | *Key Vault Secrets User* | El almacén de la demo (modelo RBAC) | Bicep | [Key Vault references](https://learn.microsoft.com/azure/app-service/app-service-key-vault-references#grant-your-app-access-to-a-key-vault) |
| Application Insights | *Monitoring Metrics Publisher*, con `APPLICATIONINSIGHTS_AUTHENTICATION_STRING` y autenticación local desactivada | El recurso de Application Insights | Bicep | [Grant permissions to an identity](https://learn.microsoft.com/azure/azure-functions/manage-connections#grant-permissions-to-an-identity) |
| IoT Hub | **Ninguno por RBAC**: el disparador no admite identidad; lee con la política `func-reader` (`ServiceConnect`) desde Key Vault | — | Bicep | ADR-005 |
| Microsoft Graph | Rol de aplicación `Sites.Selected` | Tenant | **Comando 1** del administrador (CA-06.4) | [Grant API permissions to managed identities](https://learn.microsoft.com/powershell/entra-powershell/grant-api-permissions-managed-identity) |
| Sitio de SharePoint de la demo | Rol `write` | Solo ese sitio | **Comando 2** del administrador: `POST /sites/{siteId}/permissions` con el **client ID** (appId) de `id-dsa-func` | [Create permission](https://learn.microsoft.com/graph/api/site-post-permissions) |
| Sitio `DSA-Control` | **Ninguno** | — | — | CA-06.2 lo prueba: la escritura debe fallar con 403 |
| Flujo HTTP del agente | Entrada en *Specific users in my tenant*; la otra única entrada es la cuenta del operador, solo para `demo/retrigger` y la contingencia `demo/inject` (plan §5.5) | Ese flujo | Lo configura `agente-dsa` en el diseñador con el **object ID** (principal ID) de `id-dsa-func` | ADR-003 |

Los dos comandos del administrador se ejecutan **una vez por identidad**. Si se borra el grupo de recursos, `id-dsa-func` desaparece con él; al redesplegar hay que repetir los dos comandos y actualizar el object ID en el flujo. `infra/deploy` imprime ambos valores (client ID y object ID) y los comandos listos para copiar; no se escriben en ningún archivo versionado.

Mejora posible, **fuera del alcance aprobado:** `Lists.SelectedOperations.Selected` limitaría la Function a la lista `Eventos de seguridad` en lugar de todo el sitio ([Overview of Selected permissions](https://learn.microsoft.com/graph/permissions-selected-overview)). CA-06.1 fija `Sites.Selected`; se deja como propuesta para la guía de producción.

### 3. Permisos del operador (Daniel)

| Recurso | Permiso | Motivo |
| --- | --- | --- |
| Grupo de recursos de la demo | *Owner* (o *Contributor* + *Role Based Access Control Administrator*) | Bicep crea asignaciones de roles |
| Storage | *Storage Table Data Contributor* (parámetro `operatorPrincipalId`) | `demo/reset` vacía `dedup` y `ratelimit` (ADR-006) |
| IoT Hub de la demo | *IoT Hub Registry Contributor* (parámetro `operatorPrincipalId`), con ámbito **solo el hub** | Crear `sim-01` y `preflight-01` y leer su cadena de conexión con `--auth-type login` (ver abajo) |
| Microsoft Graph (delegado) | Por script, en la tabla siguiente | CA-14.2: el reinicio usa la identidad de Daniel, no la de la Function |
| Tenant | Administrador global o de SharePoint + `Application.Read.All`, `AppRoleAssignment.ReadWrite.All` y `Sites.FullControl.All` delegados, **solo** durante los dos comandos (`Connect-MgGraph -ContextScope Process` y `Disconnect-MgGraph` al terminar) | CA-06.4. `Application.Read.All` es para `Get-MgServicePrincipal` en el comando 1 ([Grant API permissions to managed identities](https://learn.microsoft.com/powershell/entra-powershell/grant-api-permissions-managed-identity)) |

**Rol *IoT Hub Registry Contributor* del operador (revisado y aprobado por revisor-seguridad, 2026-10-26).** No estaba en la versión aprobada en la Fase 2; lo añadió `infra/modules/iothub.bicep` (T-016) y se acepta por estas razones:

- La plantilla deja **una sola** política de acceso compartido en el hub, `func-reader` con solo `ServiceConnect`, y no crea `iothubowner` (CA-04.4). Sin ese rol de datos, el operador no tendría forma de dar de alta los dispositivos sin volver a una clave con `RegistryWrite`, que sería un secreto más.
- Es el rol integrado de menor privilegio para escribir en el registro de identidades con Entra ID ([Control access to IoT Hub by using Microsoft Entra ID](https://learn.microsoft.com/azure/iot-hub/authenticate-authorize-azure-ad), [IoT Hub Registry Contributor](https://learn.microsoft.com/azure/role-based-access-control/built-in-roles/internet-of-things#iot-hub-registry-contributor)). No da `ServiceConnect` (no lee la telemetría ni envía mensajes a los dispositivos) ni permisos de control sobre el recurso.
- Ámbito: el recurso IoT Hub de la demo, no el grupo ni la suscripción. Se asigna solo si `infra/deploy` recibe el object ID de la sesión de `az` (`-SkipOperatorRoles` lo omite) y desaparece con `infra/destroy`.
- Riesgo aceptado: con el rol, el operador puede leer las claves simétricas de los dispositivos. Es el mismo dato que ya guarda en su `.env` local (CA-01.4). En producción, el alta de dispositivos la haría un proceso de aprovisionamiento (DPS) y el rol se quitaría a las personas.

**Ámbitos delegados de Graph del operador** (sesión interactiva con `-ContextScope Process`, sin caché en disco; ningún permiso de aplicación):

| Script | Ámbitos | Por qué son los mínimos |
| --- | --- | --- |
| `sharepoint/provision.ps1` | `Sites.Manage.All`, `Files.ReadWrite.All` | Crear listas y columnas exige `Sites.Manage.All` ([Create list](https://learn.microsoft.com/graph/api/list-create#permissions)); subir el `.docx` a la biblioteca de un sitio exige `Files.ReadWrite.All`, porque `Files.ReadWrite` solo cubre los archivos propios ([Upload content](https://learn.microsoft.com/graph/api/driveitem-put-content#permissions)) |
| `demo/reset.ps1`, `demo/inject.ps1` | `Sites.ReadWrite.All` | Borrar y crear elementos de lista ([Delete listItem](https://learn.microsoft.com/graph/api/listitem-delete#permissions), [Create listItem](https://learn.microsoft.com/graph/api/listitem-create#permissions)) |
| `demo/retrigger.ps1` | `Sites.Read.All` | Solo lee el elemento por `EventId` |
| `demo/measure.ps1` | `Sites.Read.All`, `ChannelMessage.Read.All`; `Team.ReadBasic.All` y `Channel.ReadBasic.All` solo si no se dan `DSA_TEAM_ID` y `DSA_CHANNEL_ID` | Leer la lista y los mensajes del canal ([List channel messages](https://learn.microsoft.com/graph/api/channel-list-messages#permissions)) |

Los tokens del flujo (`retrigger`, `inject`) y de Table Storage (`reset`) salen de la sesión de `az` del operador y no se escriben en disco ni en pantalla.

### 4. Token para el flujo HTTP y riesgo R-13

Lo documentado en Learn: (a) una identidad administrada es una entidad de servicio, (b) puede pedir tokens para cualquier recurso que admita Entra ID, (c) el disparador acepta object IDs de entidades de servicio y valida `aud`, `iss`, `tid` y `oid`.

**Lo que Learn no documenta:** que el servicio de Power Automate acepte un token emitido a una **identidad administrada**, ni el formato de `iss` que espera (los tokens de identidad administrada pueden venir del emisor v1). Por eso se registra el riesgo:

| ID | Riesgo | Probabilidad | Impacto | Prueba temprana | Alternativa |
| --- | --- | --- | --- | --- | --- |
| **R-13** | El flujo rechaza (401/403) el token de `id-dsa-func`, o el servicio no emite token para `https://service.flow.microsoft.com/` a una identidad administrada | Media | Alto: sin disparo no hay tramo 2 | **T-025** (ver `specs/03-tareas.md`): en cuanto exista la suscripción, desplegar la Function con una función de sonda temporal que pide el token con `ManagedIdentityCredential(client_id=…).get_token("https://service.flow.microsoft.com//.default")`, registra **solo** las notificaciones `aud`, `iss`, `oid` y `tid` (nunca el token) y llama a una **copia** del flujo restringida al object ID. Criterio: HTTP 202 con la identidad y rechazo con el token de usuario de Daniel. La sonda se borra al terminar | **B (preferida):** registro de aplicación `app-dsa-flow-caller` que **confía en `id-dsa-func` mediante una credencial de identidad federada**; la Function obtiene el token de la aplicación con *client credentials* usando el token de la identidad como aserción, sin secretos ni certificados ([Configure an application to trust a managed identity](https://learn.microsoft.com/entra/workload-id/workload-identity-federation-config-app-trust-managed-identity)). En el flujo se autoriza el object ID de la entidad de servicio de esa aplicación, caso que Learn sí documenta. **C:** la misma aplicación con un certificado generado y guardado en Key Vault, leído por `id-dsa-func` con *Key Vault Secrets User*; rotación anual en `infra/`. Nunca un secreto de cliente en el repositorio ni en la configuración |

Otros riesgos de identidad registrados en el plan: **R-16**, que `POST /sites/{siteId}/permissions` con el client ID de una identidad administrada no conceda el acceso esperado. Learn muestra el ejemplo con un registro de aplicación, no con una identidad administrada. Se resuelve con la prueba de CA-06.2 (escritura correcta en el sitio de la demo y 403 en `DSA-Control`) antes de E3.

## Alternativas consideradas

| Alternativa | Por qué no |
| --- | --- |
| Identidad asignada por el sistema | Su object ID cambia si se recrea la app, y la federación de la alternativa B solo admite identidades asignadas por el usuario ([Configure an application to trust a managed identity](https://learn.microsoft.com/entra/workload-id/workload-identity-federation-config-app-trust-managed-identity#configure-a-federated-identity-credential-on-an-application)) |
| `Sites.ReadWrite.All` para la Function | Acceso a todo el tenant; prohibido por el Art. 4 y por las reglas del proyecto |
| URL con firma (SAS) en el disparador del flujo, sin Entra ID | La URL sería un secreto que proteger y rotar; ADR-003 la descartó |
| *Any user in my tenant* en el flujo (como en el spike) | Cualquier cuenta del tenant de la empresa podría disparar al agente; solo se aceptaría como último recurso, con aprobación de Daniel y registro en ADR-002 |
| Clave `iothubowner` para la Function | Prohibido por CA-04.4 |

## Consecuencias

- **A favor:** ningún secreto en el repositorio ni en la configuración de la app (solo la referencia a Key Vault de la cadena de IoT Hub, deuda documentada en ADR-005); una identidad, un inventario de permisos verificable por el preflight.
- **En contra:** los dos comandos del administrador y la entrada del flujo se repiten cada vez que se recrea el grupo de recursos; el runbook lo incluye en el despliegue.
- **Revisión:** todo cambio a esta tabla pasa por el revisor-seguridad antes de cerrarse (rol arquitecto-cloud).
