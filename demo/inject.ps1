#Requires -Version 7.0
<#
.SYNOPSIS
    T-040 (HU-08 CA-08.6): contingencia sin Azure. Crea un incidente en "Eventos de seguridad" con los mismos
    campos que escribe la Function (sharepoint/columnas.json) y llama al flujo DisparoAgente con su eventId.

.DESCRIPTION
    Identidad: la sesión delegada e interactiva del operador (plan §5.5 y §6). Nada se guarda en disco.
    - Microsoft Graph (módulo Microsoft.Graph.Authentication): Connect-MgGraph -Scopes Sites.ReadWrite.All.
    - Token del flujo: token de usuario con audiencia exacta https://service.flow.microsoft.com/ (ADR-003),
      obtenido con la sesión de Azure CLI del operador (az login).
    - La cuenta del operador debe ser la segunda entrada autorizada del disparador de DisparoAgente (ADR-007).

    Variables de entorno (nunca versionadas):
      DSA_SITE_URL   URL del sitio de la demo.
      DSA_LIST_NAME  Nombre de la lista (por defecto "Eventos de seguridad").
      DSA_FLOW_URL   URL del disparador HTTP de DisparoAgente. No se imprime nunca completa.

    El agente nunca ejecuta acciones físicas: este script solo crea el registro y dispara la propuesta.

.EXAMPLE
    ./demo/inject.ps1 -Type puerta_forzada -Zone Z-01 -RawSeverity Alta -WhatIf
.EXAMPLE
    ./demo/inject.ps1 -Type acceso_denegado_repetido -Zone Z-03 -Repeticiones 4 -FechaEventoUtc 2026-11-05T03:47:00Z
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][ValidateSet('movimiento_zona_restringida', 'puerta_forzada', 'acceso_denegado_repetido')]
    [string]$Type,
    [Parameter(Mandatory)][ValidatePattern('^Z-\d{2}$')][string]$Zone,
    [ValidateSet('Baja', 'Media', 'Alta', 'Crítica')][string]$RawSeverity = 'Media',
    [ValidatePattern('^DEV-[A-Z0-9-]+$')][string]$DeviceId = 'DEV-INJECT-01',
    # Hora del evento en UTC (ISO 8601 con Z). Por defecto, ahora. Sirve para probar la regla de horario.
    [string]$FechaEventoUtc,
    [ValidateRange(1, 1000000)][int]$Repeticiones = 1,
    [switch]$EsPrueba,
    # Solo crea el elemento, sin llamar al flujo.
    [switch]$SkipFlow
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $PSScriptRoot 'DemoLogic.psm1') -Force

function Get-RequiredEnv([string]$Name) {
    $value = [Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrWhiteSpace($value)) { throw "Falta la variable de entorno $Name (ver .env.example)." }
    return $value
}

# 1. Campos del incidente: lógica pura y probada (demo/tests).
$zones = Get-Content (Join-Path $root 'data' 'zonas.json') -Raw -Encoding utf8 | ConvertFrom-Json
$contractPath = Join-Path $root 'sharepoint' 'columnas.json'
$columns = Get-FunctionColumnNames -ContractPath $contractPath
if (-not (Test-Path $contractPath)) { Write-Warning 'No existe sharepoint/columnas.json: se usan los nombres del plan §4.3.' }

$now = [DateTime]::UtcNow
$fecha = if ($FechaEventoUtc) { ConvertTo-UtcDateTime $FechaEventoUtc } else { $now }
$eventId = [guid]::NewGuid().ToString()
$fields = New-IncidentFields -EventId $eventId -DeviceId $DeviceId -Type $Type -Zone $Zone -RawSeverity $RawSeverity `
    -Zones $zones -FechaEventoUtc $fecha -RecibidoUtc $now -Repeticiones $Repeticiones -EsPrueba:$EsPrueba `
    -ColumnNames $columns

$local = ConvertTo-BogotaTime -Utc $fecha
$franja = if (Test-Daytime -Utc $fecha) { 'horario diurno' } else { 'fuera del horario diurno (la regla sube un nivel)' }
Write-Host ("Incidente {0}: {1} en {2} · {3}, {4:HH:mm} COT, {5}. SeveridadInicial = {6}, Repeticiones = {7}." -f
    $eventId, $Type, $Zone, $fields['NombreZona'], $local, $franja, $fields['SeveridadInicial'], $Repeticiones)

$listName = [Environment]::GetEnvironmentVariable('DSA_LIST_NAME')
if ([string]::IsNullOrWhiteSpace($listName)) { $listName = 'Eventos de seguridad' }
if (-not $PSCmdlet.ShouldProcess("lista $listName", "Crear el incidente $eventId y disparar al agente")) {
    $fields | ConvertTo-Json | Write-Host
    return
}

# 2. Crear el elemento con la sesión delegada del operador.
$siteUrl = [uri](Get-RequiredEnv 'DSA_SITE_URL')
$flowUrl = $null
if (-not $SkipFlow) {
    $flowUrl = Get-RequiredEnv 'DSA_FLOW_URL'
    if (-not (Test-FlowUrl $flowUrl)) { throw 'DSA_FLOW_URL no es una URL https válida.' }
}

Import-Module Microsoft.Graph.Authentication
Connect-MgGraph -Scopes 'Sites.ReadWrite.All' -NoWelcome
$site = Invoke-MgGraphRequest -Method GET -Uri "v1.0/sites/$($siteUrl.Host):$($siteUrl.AbsolutePath.TrimEnd('/'))?`$select=id"
$filter = [uri]::EscapeDataString("displayName eq '$listName'")
$list = (Invoke-MgGraphRequest -Method GET -Uri "v1.0/sites/$($site.id)/lists?`$filter=$filter&`$select=id").value |
    Select-Object -First 1
if (-not $list) { throw "No existe la lista '$listName' en el sitio de la demo." }

$item = Invoke-MgGraphRequest -Method POST -Uri "v1.0/sites/$($site.id)/lists/$($list.id)/items" `
    -Body ($fields | ConvertTo-GraphItemBody) -ContentType 'application/json'
$created = ConvertTo-UtcDateTime $item.createdDateTime
Write-Host ("Elemento creado a las {0:HH:mm:ss} UTC." -f $created)

if ($SkipFlow) { return }

# 3. Llamar a DisparoAgente con solo el eventId (plan §4.5). El token no se escribe en disco ni en pantalla.
$token = az account get-access-token --resource 'https://service.flow.microsoft.com/' --query accessToken -o tsv
if ($LASTEXITCODE -ne 0 -or -not $token) { throw 'No se pudo obtener el token del flujo con az (ejecuta az login).' }
if (-not (Test-FlowTokenAudience $token)) { throw 'El token no tiene la audiencia https://service.flow.microsoft.com/.' }

$request = New-FlowRequest -FlowUrl $flowUrl -Token $token -EventId $eventId
try {
    $response = Invoke-WebRequest @request -SkipHttpErrorCheck
}
finally {
    $token = $null; $request = $null
}
if ($response.StatusCode -ge 300) {
    throw "DisparoAgente respondió HTTP $($response.StatusCode) ($(Get-RedactedUrl $flowUrl)). El incidente queda en Nuevo: usa demo/retrigger.ps1."
}
Write-Host ("DisparoAgente aceptó el incidente (HTTP {0}). Mide con: ./demo/measure.ps1 -Last 1" -f $response.StatusCode)
