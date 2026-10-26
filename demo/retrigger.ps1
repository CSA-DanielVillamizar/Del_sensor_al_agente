#Requires -Version 7.0
<#
.SYNOPSIS
    T-048 (HU-14, ADR-004 §2): vuelve a llamar al flujo DisparoAgente para un incidente que quedó
    en 'Nuevo' porque la Function no pudo dispararlo.

.DESCRIPTION
    1. Lee el elemento de 'Eventos de seguridad' por EventId (columna indexada) y comprueba que
       sigue en 'Nuevo'. Si ya avanzó, no hace nada: así no se publica dos veces (ADR-003).
    2. Pide un token de usuario de Daniel con audiencia https://service.flow.microsoft.com/
       (az account get-access-token) y hace POST {"eventId": "..."} a DSA_FLOW_URL (cuerpo de §4.5).

    Identidad: Daniel, la segunda entrada autorizada del disparador HTTP de DisparoAgente
    ("usuarios específicos de mi inquilino", plan §5.4).
    - Graph delegado, sesión interactiva, ámbito Sites.Read.All: solo lee el elemento.
      https://learn.microsoft.com/graph/api/listitem-list#permissions
    - Token para el flujo: la sesión de 'az' de Daniel. Disparador HTTP con autenticación OAuth:
      https://learn.microsoft.com/power-automate/oauth-authentication
    DSA_FLOW_URL es una variable de entorno (o del .env, que no se versiona). La URL y el token
    nunca se escriben en pantalla ni en archivos; solo se muestra el host.

.PARAMETER EventId
    EventId del incidente (UUID en minúsculas, como en schemas/evento-dispositivo.schema.json).

.EXAMPLE
    $env:DSA_FLOW_URL = '<URL del disparador HTTP de DisparoAgente>'
    pwsh -File demo/retrigger.ps1 -EventId 3f2b8a4e-6c1d-4e9a-9f7b-2d5c8e1a0b37
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string] $EventId,
    [string] $SiteUrl,
    [string] $ListName,
    [string] $EnvFile
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

$dryRun = [bool]$WhatIfPreference
$WhatIfPreference = $false

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
Import-Module (Join-Path $PSScriptRoot 'ResetLogic.psm1') -Force

$RequiredScopes = @('Sites.Read.All')
$FlowResource = 'https://service.flow.microsoft.com/'

function Write-DsaLine {
    param([string] $Status, [string] $Message)
    $line = Format-DsaLine -Status $Status -Message $Message
    Write-Host $line.Text -ForegroundColor $line.Color
}

Write-Host ''
Write-Host 'Reintento del disparo al agente (T-048)' -ForegroundColor White
if ($dryRun) { Write-Host 'Modo -WhatIf: se lee el estado, no se llama al flujo.' -ForegroundColor Yellow }

if (-not (Test-DsaEventId $EventId)) {
    Write-DsaLine Error "EventId no válido: '$EventId'. Debe ser un UUID en minúsculas."
    exit 2
}

if (-not $EnvFile) { $EnvFile = Join-Path $repoRoot '.env' }
$dotEnv = if (Test-Path -LiteralPath $EnvFile) { ConvertFrom-DsaDotEnv -Lines (Get-Content -LiteralPath $EnvFile) } else { @{} }
$processEnv = @{}
foreach ($name in 'DSA_SITE_URL', 'DSA_LIST_NAME', 'DSA_FLOW_URL') { $processEnv[$name] = [Environment]::GetEnvironmentVariable($name) }
$SiteUrl = Resolve-DsaSetting -Explicit $SiteUrl -Name 'DSA_SITE_URL' -DotEnv $dotEnv -ProcessEnv $processEnv
$ListName = Resolve-DsaSetting -Explicit $ListName -Name 'DSA_LIST_NAME' -DotEnv $dotEnv -ProcessEnv $processEnv -Default 'Eventos de seguridad'
$flowUrl = Resolve-DsaSetting -Explicit $null -Name 'DSA_FLOW_URL' -DotEnv $dotEnv -ProcessEnv $processEnv

if (-not $SiteUrl) { Write-DsaLine Error 'Falta la URL del sitio: usa -SiteUrl o define DSA_SITE_URL en .env.'; exit 2 }
if (-not $dryRun -and -not (Test-DsaFlowUrl $flowUrl)) {
    Write-DsaLine Error "Falta DSA_FLOW_URL (https). Defínela en la sesión: `$env:DSA_FLOW_URL = '<URL del disparador HTTP de DisparoAgente>'"
    exit 2
}
if (-not (Get-Module -ListAvailable -Name 'Microsoft.Graph.Authentication')) {
    Write-DsaLine Error 'Falta el módulo Microsoft.Graph.Authentication. Instálalo con: Install-Module Microsoft.Graph.Authentication -Scope CurrentUser'
    exit 3
}

# --- 1. Estado del incidente --------------------------------------------------------------------

Import-Module Microsoft.Graph.Authentication
$context = Get-MgContext
# Una sesión previa con Sites.ReadWrite.All (de reset) también sirve para leer.
$granted = if ($context) { @($context.Scopes) } else { @() }
$readOk = (Get-DsaMissingScopes -Granted $granted -Required $RequiredScopes).Count -eq 0 -or
          (Get-DsaMissingScopes -Granted $granted -Required @('Sites.ReadWrite.All')).Count -eq 0
if (-not $context -or $context.AuthType -ne 'Delegated' -or -not $readOk) {
    Write-Host "Inicio de sesión delegado e interactivo con: $($RequiredScopes -join ', ')" -ForegroundColor Cyan
    Connect-MgGraph -Scopes $RequiredScopes -ContextScope Process -NoWelcome
}
$invoker = { param($u) Invoke-MgGraphRequest -Method GET -Uri $u -OutputType HashTable }

$site = Invoke-MgGraphRequest -Method GET -Uri "v1.0/sites/$(ConvertTo-DsaSitePath -SiteUrl $SiteUrl)?`$select=id" -OutputType HashTable
$siteId = [string](Get-DsaValue $site 'id')
$list = Find-DsaListByDisplayName -Lists (Invoke-DsaGraphPaged -Uri "v1.0/sites/$siteId/lists?`$select=id,displayName" -Invoker $invoker) -DisplayName $ListName
if (-not $list) { Write-DsaLine Error "No existe la lista '$ListName'."; exit 1 }

$items = Invoke-DsaGraphPaged -Invoker $invoker -Uri (Get-DsaItemByEventIdUri -SiteId $siteId -ListId ([string](Get-DsaValue $list 'id')) -EventId $EventId)
$decision = Get-DsaRetriggerDecision -Items $items

switch ($decision.Action) {
    'NotFound' { Write-DsaLine Error "EventId $EventId`: $($decision.Reason)."; exit 1 }
    'Ambiguous' { Write-DsaLine Error "EventId $EventId`: $($decision.Reason)."; exit 1 }
    'Skip' { Write-DsaLine Exists "EventId $EventId $($decision.Reason). No se llama al flujo."; exit 0 }
}

Write-DsaLine Info "EventId $EventId $($decision.Reason)."
if ($dryRun) {
    Write-DsaLine WhatIf "POST {`"eventId`"} al flujo en $(Get-DsaSafeHost $flowUrl)"
    exit 0
}

# --- 2. Llamada al flujo ------------------------------------------------------------------------

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    Write-DsaLine Error 'No está la CLI de Azure (az). Instálala: https://learn.microsoft.com/cli/azure/install-azure-cli'
    exit 3
}
$token = (& az account get-access-token --resource $FlowResource --query accessToken --output tsv)
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($token)) {
    Write-DsaLine Error "No se obtuvo el token para $FlowResource. Revisa la sesión con 'az account show'."
    exit 3
}

try {
    $request = New-DsaFlowRequest -FlowUrl $flowUrl -EventId $EventId -AccessToken ([string]$token).Trim()
    $response = Invoke-WebRequest @request -SkipHttpErrorCheck
    $code = [int]$response.StatusCode
}
finally {
    $token = $null
    $request = $null
}

if ($code -ge 200 -and $code -lt 300) {
    Write-DsaLine Updated "Flujo llamado en $(Get-DsaSafeHost $flowUrl): HTTP $code. El incidente debería pasar a 'Pendiente de decisión'."
    exit 0
}
if ($code -in 401, 403) {
    Write-DsaLine Error "HTTP $code`: la cuenta de 'az' no está entre los usuarios autorizados del disparador de DisparoAgente (plan §5.4)."
    exit 1
}
Write-DsaLine Error "El flujo respondió HTTP $code."
exit 1
