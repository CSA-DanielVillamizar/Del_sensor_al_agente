#Requires -Version 7.0
<#
.SYNOPSIS
    T-047 (HU-14 CA-14.3): comprueba en ≤ 3 minutos que la demo está lista, con verde, amarillo o rojo
    por componente.

.DESCRIPTION
    Comprobaciones, en este orden:
      1. PowerShell 7 o superior.
      2. Azure: IoT Hub activo, dispositivo preflight-01 habilitado y Function en ejecución.
      3. SharePoint: la lista de incidentes responde.
      4. Entorno de Power Platform (DSA_ENVIRONMENT_KIND): verde si es Sandbox, amarillo si es el
         predeterminado (ADR-002).
      5. Auditoría de Dataverse activada (isauditenabled de la organización, DSA_DATAVERSE_URL).
      6. Cómo se pagan los créditos (DSA_CREDITS_MODE) y, si la capacidad es de prueba, los días hasta
         su vencimiento (DSA_TRIAL_END) frente a la fecha de la sesión (DSA_SESSION_DATE).
      7. Consumo del mes frente al límite del agente (DSA_CREDITS_USED y DSA_CREDITS_LIMIT). Learn no
         ofrece una API pública documentada para leer ese consumo: el dato se copia del centro de
         administración de Power Platform y, si falta, el resultado es amarillo.
      8. Nueva infraestructura de Power Platform (DSA_NEW_INFRA): se informa.
      9. Punta a punta: envía un evento con el dispositivo preflight-01 (la Function marca EsPrueba) y
         espera a que el incidente llegue a 'Pendiente de decisión'. Publica una tarjeta en el canal.

    Identidad: la de Daniel. Azure con la sesión de az; Graph delegado (Sites.ReadWrite.All, el mismo de
    reset.ps1, para que una sola sesión sirva a los dos) con -ContextScope Process. Ningún token ni
    cadena de conexión se escribe en pantalla ni en disco.

.EXAMPLE
    pwsh -File demo/preflight.ps1
    pwsh -File demo/preflight.ps1 -SkipEndToEnd
#>
[CmdletBinding()]
param(
    [string] $EnvFile,
    [string] $DeploymentName = 'dsa-main',
    [ValidateRange(30, 170)][int] $TimeoutSeconds = 90,
    [switch] $SkipEndToEnd
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

$stopwatch = [Diagnostics.Stopwatch]::StartNew()
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
Import-Module (Join-Path $PSScriptRoot 'PreflightLogic.psm1') -Force
Import-Module (Join-Path $repoRoot 'sharepoint' 'ProvisionLogic.psm1') -Force

$checks = [System.Collections.Generic.List[object]]::new()
function Add-DsaCheck([object] $Check) {
    $checks.Add($Check)
    $line = Format-DsaCheck -Check $Check
    Write-Host $line.Text -ForegroundColor $line.Color
}

function Invoke-DsaAz {
    param([Parameter(Mandatory)][string[]] $Arguments)
    $output = & az @Arguments 2>$null
    if ($LASTEXITCODE -ne 0) { Write-Verbose "az $($Arguments[0..2] -join ' ') terminó con código $LASTEXITCODE"; return $null }
    return ($output -join "`n").Trim()
}

Write-Host ''
Write-Host 'Preflight de la demo (T-047)' -ForegroundColor White

if (-not $EnvFile) { $EnvFile = Join-Path $repoRoot '.env' }
$dotEnv = if (Test-Path -LiteralPath $EnvFile) { ConvertFrom-DsaDotEnv -Lines (Get-Content -LiteralPath $EnvFile) } else { @{} }
$names = 'DSA_RESOURCE_GROUP', 'DSA_SITE_URL', 'DSA_LIST_NAME', 'DSA_ENVIRONMENT_KIND', 'DSA_SESSION_DATE', 'DSA_DATAVERSE_URL',
    'DSA_CREDITS_MODE', 'DSA_TRIAL_END', 'DSA_CREDITS_USED', 'DSA_CREDITS_LIMIT', 'DSA_NEW_INFRA', 'IOTHUB_PREFLIGHT_CONNECTION_STRING'
$processEnv = @{}
foreach ($n in $names) { $processEnv[$n] = [Environment]::GetEnvironmentVariable($n) }
$cfg = @{}
foreach ($n in $names) { $cfg[$n] = Resolve-DsaSetting -Explicit $null -Name $n -DotEnv $dotEnv -ProcessEnv $processEnv }
if (-not $cfg['DSA_LIST_NAME']) { $cfg['DSA_LIST_NAME'] = 'Eventos de seguridad' }

# 1. PowerShell
Add-DsaCheck (Get-DsaPwshCheck -Major $PSVersionTable.PSVersion.Major)

# 2. Azure
$rg = $cfg['DSA_RESOURCE_GROUP']
if (-not $rg) {
    Add-DsaCheck (New-DsaCheck 'Azure' 'Rojo' 'Falta DSA_RESOURCE_GROUP en .env.')
}
else {
    $outputs = Invoke-DsaAz @('deployment', 'group', 'show', '--resource-group', $rg, '--name', $DeploymentName, '--query', 'properties.outputs', '--output', 'json')
    if (-not $outputs) {
        Add-DsaCheck (New-DsaCheck 'Azure' 'Rojo' "No se pudo leer el despliegue $DeploymentName (az login y la suscripción de la demo).")
    }
    else {
        $out = $outputs | ConvertFrom-Json
        $hub = $out.iotHubName.value
        $func = $out.functionAppName.value
        Add-DsaCheck (Get-DsaResourceCheck -Name 'IoT Hub' -Expected 'Active' -Actual (Invoke-DsaAz @('iot', 'hub', 'show', '--name', $hub, '--resource-group', $rg, '--query', 'properties.state', '--output', 'tsv')))
        Add-DsaCheck (Get-DsaResourceCheck -Name 'Dispositivo preflight-01' -Expected 'enabled' -Actual (Invoke-DsaAz @('iot', 'hub', 'device-identity', 'show', '--hub-name', $hub, '--device-id', 'preflight-01', '--auth-type', 'login', '--query', 'status', '--output', 'tsv')))
        Add-DsaCheck (Get-DsaResourceCheck -Name 'Function' -Expected 'Running' -Actual (Invoke-DsaAz @('functionapp', 'show', '--name', $func, '--resource-group', $rg, '--query', 'properties.state', '--output', 'tsv')))
    }
}

# 3. SharePoint
$site = $null; $list = $null
if (-not $cfg['DSA_SITE_URL']) {
    Add-DsaCheck (New-DsaCheck 'SharePoint' 'Rojo' 'Falta DSA_SITE_URL en .env.')
}
else {
    try {
        Import-Module Microsoft.Graph.Authentication
        $context = Get-MgContext
        $granted = if ($context) { @($context.Scopes) } else { @() }
        if (-not $context -or $context.AuthType -ne 'Delegated' -or @(Get-DsaMissingScopes -Granted $granted -Required @('Sites.ReadWrite.All')).Count -gt 0) {
            # -ContextScope Process: el token vive solo en este proceso.
            Connect-MgGraph -Scopes 'Sites.ReadWrite.All' -ContextScope Process -NoWelcome
        }
        $site = Invoke-MgGraphRequest -Method GET -Uri "v1.0/sites/$(ConvertTo-DsaSitePath -SiteUrl $cfg['DSA_SITE_URL'])?`$select=id" -OutputType HashTable
        $lists = Invoke-DsaGraphPaged -Uri "v1.0/sites/$($site['id'])/lists?`$select=id,displayName" -Invoker { param($u) Invoke-MgGraphRequest -Method GET -Uri $u -OutputType HashTable }
        $list = Find-DsaListByDisplayName -Lists $lists -DisplayName $cfg['DSA_LIST_NAME']
        if ($list) { Add-DsaCheck (New-DsaCheck 'SharePoint' 'Verde' "La lista '$($cfg['DSA_LIST_NAME'])' responde.") }
        else { Add-DsaCheck (New-DsaCheck 'SharePoint' 'Rojo' "No existe la lista '$($cfg['DSA_LIST_NAME'])': ejecuta sharepoint/provision.ps1.") }
    }
    catch { Add-DsaCheck (New-DsaCheck 'SharePoint' 'Rojo' "Graph respondió con error: $($_.Exception.Message)") }
}

# 4. Entorno
Add-DsaCheck (Get-DsaEnvironmentKindCheck -Kind $cfg['DSA_ENVIRONMENT_KIND'])

# 5. Auditoría de Dataverse
$audit = $null
if ($cfg['DSA_DATAVERSE_URL']) {
    $org = $cfg['DSA_DATAVERSE_URL'].TrimEnd('/')
    $raw = Invoke-DsaAz @('rest', '--method', 'get', '--resource', $org, '--url', "$org/api/data/v9.2/organizations?`$select=isauditenabled", '--query', 'value[0].isauditenabled', '--output', 'tsv')
    if ($raw) { $audit = $raw -eq 'true' }
}
Add-DsaCheck (Get-DsaAuditCheck -IsAuditEnabled $audit)

# 6 y 7. Créditos
$session = if ($cfg['DSA_SESSION_DATE']) { [datetime]$cfg['DSA_SESSION_DATE'] } else { [datetime]'2026-11-04' }
$trialEnd = if ($cfg['DSA_TRIAL_END']) { [datetime]$cfg['DSA_TRIAL_END'] } else { $null }
Add-DsaCheck (Get-DsaCreditsCheck -Mode $cfg['DSA_CREDITS_MODE'] -TrialEnd $trialEnd -SessionDate $session -Today ([datetime]::UtcNow))
$used = if ($cfg['DSA_CREDITS_USED']) { [double]$cfg['DSA_CREDITS_USED'] } else { $null }
$limit = if ($cfg['DSA_CREDITS_LIMIT']) { [double]$cfg['DSA_CREDITS_LIMIT'] } else { 3000 }
Add-DsaCheck (Get-DsaConsumptionCheck -Used $used -Limit $limit)

# 8. Infraestructura
Add-DsaCheck (Get-DsaInfrastructureCheck -Value $cfg['DSA_NEW_INFRA'])

# 9. Punta a punta
if ($SkipEndToEnd) {
    Add-DsaCheck (New-DsaCheck 'Punta a punta' 'Amarillo' 'Omitida (-SkipEndToEnd).')
}
elseif (-not $cfg['IOTHUB_PREFLIGHT_CONNECTION_STRING'] -or -not $list) {
    Add-DsaCheck (New-DsaCheck 'Punta a punta' 'Rojo' 'Falta IOTHUB_PREFLIGHT_CONNECTION_STRING en .env o la lista no responde.')
}
else {
    $start = [datetime]::UtcNow
    $python = Join-Path $repoRoot '.venv' 'Scripts' 'python.exe'
    if (-not (Test-Path $python)) { $python = 'python' }
    $previous = $env:IOTHUB_DEVICE_CONNECTION_STRING
    try {
        # El simulador lee la cadena del entorno antes que del .env: así envía como preflight-01.
        $env:IOTHUB_DEVICE_CONNECTION_STRING = $cfg['IOTHUB_PREFLIGHT_CONNECTION_STRING']
        Push-Location $repoRoot
        & $python -m simulator --type acceso_denegado_repetido --zone Z-04 --severity Baja --device DEV-PREFLIGHT-01 | Out-Null
        $sent = $LASTEXITCODE -eq 0
    }
    finally {
        Pop-Location
        $env:IOTHUB_DEVICE_CONNECTION_STRING = $previous
    }
    if (-not $sent) {
        Add-DsaCheck (New-DsaCheck 'Punta a punta' 'Rojo' 'El simulador no pudo enviar el evento de preflight-01.')
    }
    else {
        $estado = $null
        $filter = [uri]::EscapeDataString("fields/DeviceId eq 'DEV-PREFLIGHT-01'")
        $uri = "v1.0/sites/$($site['id'])/lists/$($list['id'])/items?`$expand=fields(`$select=Estado,DeviceId,Created)&`$filter=$filter&`$top=50"
        do {
            Start-Sleep -Seconds 3
            $r = Invoke-MgGraphRequest -Method GET -Uri $uri -Headers @{ Prefer = 'HonorNonIndexedQueriesWarningMayFailRandomly' } -OutputType HashTable
            $items = @($r['value'] | ForEach-Object { [pscustomobject]@{ Created = $_['createdDateTime']; Estado = $_['fields']['Estado'] } })
            $newest = Select-DsaNewestSince -Items $items -Since $start.AddSeconds(-5)
            $estado = if ($newest) { $newest.Estado } else { $null }
            $elapsed = ([datetime]::UtcNow - $start).TotalSeconds
        } while ($estado -ne 'Pendiente de decisión' -and $elapsed -lt $TimeoutSeconds)
        Add-DsaCheck (Get-DsaEndToEndCheck -Estado $estado -ElapsedSeconds $elapsed -TimeoutSeconds $TimeoutSeconds)
    }
}

$overall = Get-DsaOverallStatus -Checks $checks.ToArray()
$color = @{ Verde = 'Green'; Amarillo = 'Yellow'; Rojo = 'Red' }[$overall]
Write-Host ''
Write-Host ("Resultado: {0} en {1:N0} s (objetivo ≤ 180 s)." -f $overall.ToUpperInvariant(), $stopwatch.Elapsed.TotalSeconds) -ForegroundColor $color
if ($overall -eq 'Rojo') { exit 1 }
