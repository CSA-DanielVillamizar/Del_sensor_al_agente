#Requires -Version 7.0
<#
.SYNOPSIS
Concede a la identidad administrada de la Function el permiso Sites.Selected con rol write solo sobre el sitio de la demo (T-024, CA-06.1, CA-06.4).

.DESCRIPTION
Ejecuta los dos comandos del administrador documentados en docs/admin-sites-selected.md:
  1. Asigna el rol de aplicación Sites.Selected de Microsoft Graph a la entidad de servicio de la identidad.
  2. Concede el rol write sobre el sitio de la demo con POST /sites/{siteId}/permissions.
Después comprueba que el sitio de control no tiene ningún permiso para la identidad.

Es idempotente: si la asignación o el permiso ya existen, no los duplica.
Usa solo el módulo Microsoft.Graph.Authentication (Invoke-MgGraphRequest) y una sesión delegada interactiva
del administrador, guardada solo en el proceso (-ContextScope Process) y cerrada al terminar.
No escribe ningún identificador en archivos.

.PARAMETER ObjectId
Object ID (principal ID) de la identidad administrada. Lo imprime infra/deploy.

.PARAMETER ClientId
Client ID (appId) de la identidad administrada. Lo imprime infra/deploy.

.PARAMETER SiteUrl
URL del sitio de la demo, por ejemplo https://contoso.sharepoint.com/sites/demo.

.PARAMETER ControlSiteUrl
URL del sitio de control vacío (CA-06.2). Opcional: si se indica, se comprueba que no tiene permisos para la identidad.

.PARAMETER UseDeviceCode
Inicia sesión con código de dispositivo (útil en consolas sin navegador integrado).

.EXAMPLE
./infra/grant-sites-selected.ps1 -ObjectId <objectId> -ClientId <clientId> -SiteUrl https://contoso.sharepoint.com/sites/demo -ControlSiteUrl https://contoso.sharepoint.com/sites/control
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F-]{36}$')][string] $ObjectId,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F-]{36}$')][string] $ClientId,
    [Parameter(Mandatory)][ValidatePattern('^https://[^/]+/sites/[^/]+$')][string] $SiteUrl,
    [ValidatePattern('^https://[^/]+/sites/[^/]+$')][string] $ControlSiteUrl,
    [string] $DisplayName = 'id-dsa-func',
    [switch] $UseDeviceCode
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

# Identificadores públicos y fijos de Microsoft Graph (no son secretos):
# appId de la API de Microsoft Graph y id del rol de aplicación Sites.Selected
# (https://learn.microsoft.com/graph/permissions-reference#sitesselected).
$GraphAppId = '00000003-0000-0000-c000-000000000000'
$SitesSelectedRoleId = '883ea226-0bf2-4a8f-9f9d-92c9162a727d'
$Scopes = @('Application.Read.All', 'AppRoleAssignment.ReadWrite.All', 'Sites.FullControl.All')

function Get-DsaSiteId {
    param([Parameter(Mandatory)][string] $Url)
    $uri = [uri]$Url
    $site = Invoke-MgGraphRequest -Method GET -Uri "v1.0/sites/$($uri.Host):$($uri.AbsolutePath)?`$select=id,displayName"
    return [pscustomobject]@{ Id = [string]$site.id; Name = [string]$site.displayName }
}

function Get-DsaIdentityPermissions {
    param([Parameter(Mandatory)][string] $SiteId, [Parameter(Mandatory)][string] $AppId)
    $perms = (Invoke-MgGraphRequest -Method GET -Uri "v1.0/sites/$SiteId/permissions").value
    return @($perms | Where-Object {
            $_.grantedToIdentitiesV2.application.id -contains $AppId -or $_.grantedToIdentities.application.id -contains $AppId
        })
}

if (-not (Get-Module -ListAvailable Microsoft.Graph.Authentication)) {
    Write-Host 'Falta el módulo Microsoft.Graph.Authentication. Instálalo con: Install-PSResource Microsoft.Graph.Authentication -Scope CurrentUser' -ForegroundColor Red
    exit 3
}
Import-Module Microsoft.Graph.Authentication

$connect = @{ Scopes = $Scopes; ContextScope = 'Process'; NoWelcome = $true }
if ($UseDeviceCode) { $connect.UseDeviceCode = $true }
Connect-MgGraph @connect
try {
    # --- Comando 1: rol de aplicación Sites.Selected -------------------------------------------
    $graphSp = (Invoke-MgGraphRequest -Method GET -Uri "v1.0/servicePrincipals?`$filter=appId eq '$GraphAppId'&`$select=id").value | Select-Object -First 1
    if (-not $graphSp) { throw 'No se encontró la entidad de servicio de Microsoft Graph en el tenant.' }
    $existing = (Invoke-MgGraphRequest -Method GET -Uri "v1.0/servicePrincipals/$ObjectId/appRoleAssignments").value |
        Where-Object { $_.appRoleId -eq $SitesSelectedRoleId -and $_.resourceId -eq $graphSp.id }
    if ($existing) {
        Write-Host '[ya existía]  rol de aplicación Sites.Selected asignado a la identidad'
    }
    elseif ($PSCmdlet.ShouldProcess($DisplayName, 'Asignar el rol de aplicación Sites.Selected')) {
        $body = @{ principalId = $ObjectId; resourceId = $graphSp.id; appRoleId = $SitesSelectedRoleId }
        $null = Invoke-MgGraphRequest -Method POST -Uri "v1.0/servicePrincipals/$ObjectId/appRoleAssignments" -Body $body
        Write-Host '[creado]      rol de aplicación Sites.Selected asignado a la identidad'
    }

    # --- Comando 2: write solo sobre el sitio de la demo ------------------------------------
    $site = Get-DsaSiteId -Url $SiteUrl
    $granted = @(Get-DsaIdentityPermissions -SiteId $site.Id -AppId $ClientId)
    if ($granted | Where-Object { $_.roles -contains 'write' }) {
        Write-Host "[ya existía]  permiso write de la identidad en el sitio '$($site.Name)'"
    }
    elseif ($PSCmdlet.ShouldProcess($site.Name, 'Conceder el rol write a la identidad')) {
        $body = @{
            roles               = @('write')
            grantedToIdentities = @(@{ application = @{ id = $ClientId; displayName = $DisplayName } })
        }
        $null = Invoke-MgGraphRequest -Method POST -Uri "v1.0/sites/$($site.Id)/permissions" -Body $body
        Write-Host "[creado]      permiso write de la identidad en el sitio '$($site.Name)'"
    }

    # --- Comprobaciones ------------------------------------------------------------------------
    $after = @(Get-DsaIdentityPermissions -SiteId $site.Id -AppId $ClientId)
    Write-Host ("[comprobado]  sitio de la demo: roles de la identidad = {0}" -f ((@($after | ForEach-Object { $_.roles }) | Sort-Object -Unique) -join ', '))
    if ($ControlSiteUrl) {
        $control = Get-DsaSiteId -Url $ControlSiteUrl
        $controlPerms = @(Get-DsaIdentityPermissions -SiteId $control.Id -AppId $ClientId)
        if ($controlPerms.Count -eq 0) {
            Write-Host "[comprobado]  sitio de control '$($control.Name)': la identidad no tiene ningún permiso (CA-06.2)"
        }
        else {
            Write-Host "[ERROR]       el sitio de control '$($control.Name)' tiene permisos para la identidad: revísalo" -ForegroundColor Red
            exit 5
        }
    }
}
finally {
    Disconnect-MgGraph | Out-Null
    Write-Host 'Sesión de administrador cerrada.'
}
