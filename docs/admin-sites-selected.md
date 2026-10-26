# Comandos del administrador: `Sites.Selected` para `id-dsa-func`

| Campo | Valor |
| --- | --- |
| Historia | HU-06 (CA-06.1, CA-06.2, CA-06.4) |
| Tareas | T-019 (los imprime `infra/deploy`), T-024 (se ejecutan y se prueban) |
| Decisión | [ADR-007](adr/ADR-007-identidad-y-permisos.md) §2 |
| Revisión | revisor-seguridad (T-045) |

La Function escribe en SharePoint con su identidad administrada `id-dsa-func` y el permiso de aplicación `Sites.Selected` de Microsoft Graph, limitado al rol `write` sobre **un solo sitio**: el de la demo. El sitio de control `DSA-Control` no recibe nada y la escritura allí debe fallar con 403 (CA-06.2).

Hacen falta dos comandos del administrador del tenant. Se ejecutan **una vez por identidad**: si se borra el grupo de recursos, `id-dsa-func` desaparece y hay que repetirlos con los nuevos valores (ADR-007).

## Valores que necesitas

| Marcador | Qué es | De dónde sale |
| --- | --- | --- |
| `<objectId>` | Object ID (principal ID) de la entidad de servicio de `id-dsa-func` | Lo imprime `infra/deploy` al final; también `az identity show -g rg-dsa-demo -n id-dsa-func --query principalId -o tsv` |
| `<clientId>` | Client ID (appId) de `id-dsa-func` | Lo imprime `infra/deploy`; también `az identity show -g rg-dsa-demo -n id-dsa-func --query clientId -o tsv` |
| `<siteId>` | ID del sitio de la demo, con la forma `{hostname},{siteCollectionId},{webId}` | `(Get-MgSite -SiteId '<hostname>:/sites/<rutaDelSitio>').Id` después de conectarte |

Ningún valor real se escribe en este repositorio. `infra/deploy` imprime los comandos con `<objectId>` y `<clientId>` ya sustituidos para copiarlos en la consola.

## Requisitos de quien ejecuta los comandos

- Rol de **SharePoint Administrator** o superior, y ser **miembro del sitio** de la demo: lo exige `POST /sites/{siteId}/permissions` en modo delegado ([Create permission](https://learn.microsoft.com/graph/api/site-post-permissions)).
- Consentimiento delegado de `AppRoleAssignment.ReadWrite.All` y `Application.Read.All` para el comando 1 ([Grant API permissions to managed identities](https://learn.microsoft.com/powershell/entra-powershell/grant-api-permissions-managed-identity)) y de `Sites.FullControl.All` para el comando 2, que es el único permiso admitido por esa API ([Create permission](https://learn.microsoft.com/graph/api/site-post-permissions)).
- PowerShell 7 con el módulo `Microsoft.Graph` (submódulos `Applications` y `Sites`).
- Estos permisos son de la sesión del administrador, **no** de la Function. La Function solo recibe `Sites.Selected`.

## Sesión

```powershell
Connect-MgGraph -Scopes 'Application.Read.All','AppRoleAssignment.ReadWrite.All','Sites.FullControl.All'
```

## Comando 1: asignar el rol de aplicación `Sites.Selected` a la identidad administrada

Asigna el rol de aplicación `Sites.Selected` (identificador `883ea226-0bf2-4a8f-9f9d-92c9162a727d`, [Microsoft Graph permissions reference](https://learn.microsoft.com/graph/permissions-reference#sitesselected)) de la entidad de servicio de Microsoft Graph (appId `00000003-0000-0000-c000-000000000000`) a la entidad de servicio de `id-dsa-func`. Las identidades administradas reciben permisos de Graph con una asignación de rol de aplicación, no desde el portal ([Grant API permissions to managed identities](https://learn.microsoft.com/powershell/entra-powershell/grant-api-permissions-managed-identity)).

```powershell
New-MgServicePrincipalAppRoleAssignment -ServicePrincipalId '<objectId>' -PrincipalId '<objectId>' -ResourceId (Get-MgServicePrincipal -Filter "appId eq '00000003-0000-0000-c000-000000000000'").Id -AppRoleId '883ea226-0bf2-4a8f-9f9d-92c9162a727d'
```

Por sí solo, `Sites.Selected` no da acceso a ningún sitio ([Overview of Selected permissions](https://learn.microsoft.com/graph/permissions-selected-overview)).

## Comando 2: conceder `write` solo sobre el sitio de la demo

`POST /sites/{siteId}/permissions` con el **client ID** de la identidad en `grantedToIdentities.application.id` ([Create permission](https://learn.microsoft.com/graph/api/site-post-permissions)).

```powershell
New-MgSitePermission -SiteId '<siteId>' -BodyParameter @{ roles = @('write'); grantedToIdentities = @(@{ application = @{ id = '<clientId>'; displayName = 'id-dsa-func' } }) }
```

Respuesta esperada: `201 Created` con `roles = write`.

## Comprobación (T-024)

1. Ver el permiso concedido: `Get-MgSitePermission -SiteId '<siteId>'` muestra una entrada con `id-dsa-func` y `write`.
2. Ver que `DSA-Control` no tiene permiso: `Get-MgSitePermission -SiteId '<siteIdDeControl>'` no muestra `id-dsa-func`.
3. Desde la Function, crear un elemento en `Eventos de seguridad` (éxito) e intentar escribir en `DSA-Control` (403). La salida se guarda como evidencia de CA-06.1 y CA-06.2.

**Riesgo R-16:** Learn muestra el comando 2 con un registro de aplicación, no con una identidad administrada. Si la comprobación falla, el plan B de ADR-007 es un registro de aplicación con credencial federada que confía en `id-dsa-func`.

## Revocar

```powershell
Get-MgSitePermission -SiteId '<siteId>' | Where-Object { $_.Roles -contains 'write' }
Remove-MgSitePermission -SiteId '<siteId>' -PermissionId '<permissionId>'
Get-MgServicePrincipalAppRoleAssignment -ServicePrincipalId '<objectId>'
Remove-MgServicePrincipalAppRoleAssignment -ServicePrincipalId '<objectId>' -AppRoleAssignmentId '<appRoleAssignmentId>'
```

Borrar el grupo de recursos con `infra/destroy` elimina la identidad y, con ella, sus asignaciones.
