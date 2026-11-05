#Requires -Version 7.0
<#
.SYNOPSIS
    Arma el .zip de la solución "Del sensor al agente" con los valores de tu tenant.

.DESCRIPTION
    Lee los valores de los parámetros o, si no se pasan, de las variables de entorno
    (carga .env antes de ejecutarlo). Reemplaza los marcadores de src/ y deja el
    paquete en agent/solucion/out/, que está fuera del control de versiones.

.EXAMPLE
    ./agent/solucion/pack.ps1
    ./agent/solucion/pack.ps1 -SiteUrl https://contoso.sharepoint.com/sites/DSA-Demo-Site -TeamId <guid> -ChannelId '19:...@thread.tacv2' -AllowedUsers <objectId>
#>
[CmdletBinding()]
param(
    [string] $SiteUrl = $env:DSA_SITE_URL,
    [string] $TeamId = $env:DSA_TEAM_ID,
    [string] $ChannelId = $env:DSA_CHANNEL_ID,
    [string] $AllowedUsers = $env:DSA_FLOW_ALLOWED_USERS,
    [string] $OutputZip = (Join-Path $PSScriptRoot 'out/DelSensorAlAgente.zip')
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'SolucionLogic.psm1') -Force

$values = @{
    '{{DSA_SITE_URL}}'           = $SiteUrl
    '{{DSA_TEAM_ID}}'            = $TeamId
    '{{DSA_CHANNEL_ID}}'         = $ChannelId
    '{{DSA_FLOW_ALLOWED_USERS}}' = $AllowedUsers
}

$errors = @(Test-DsaSolutionValues -Values $values)
if ($errors.Count -gt 0) {
    $errors | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    throw 'Faltan valores o no tienen el formato esperado. Revisa .env (ver agent/solucion/README.md).'
}

$zip = New-DsaSolutionPackage -SourcePath (Join-Path $PSScriptRoot 'src') -OutputZip $OutputZip -Values $values
Write-Host "Paquete listo: $zip" -ForegroundColor Green
Write-Host 'Impórtalo en Copilot Studio > Soluciones > Importar solución (ver agent/solucion/README.md).'
