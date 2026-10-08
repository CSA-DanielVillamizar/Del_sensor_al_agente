#Requires -Version 7.0
<#
.SYNOPSIS
    SPK-01: emite N eventos de prueba por la opción A (SharePoint), B (Dataverse) o C (HTTP) y registra T0.
.DESCRIPTION
    Código desechable del spike de latencia. Las credenciales se obtienen con identidad delegada
    (Connect-MgGraph y az login); ninguna URL ni secreto se escribe en disco.

    Dos condiciones de corte (lógica en SpikeLogic.psm1); cualquiera detiene la opción y la registra
    en resultados/cortes.csv:
    1. Corte p90 (agresivo): en cuanto Get-MaxSlow eventos (3 con 20 muestras) superan TargetSeconds
       en el tramo 2, o llevan más de TargetSeconds sin reacción. Se revisa antes de emitir cada evento.
    2. Corte de protección: CutoffSeconds después del evento CutoffSample, si ninguno completó el
       tramo 2 en CutoffSeconds o menos.

    -DryRun ejecuta exactamente el mismo bucle con un reloj virtual y las latencias de
    -SyntheticLatency ($null = sin reacción). No se conecta a nada, no espera y no escribe archivos.
.EXAMPLE
    ./Invoke-LatencySpike.ps1 -Option A -DryRun -SyntheticLatency 5,30,5,30,5,5,30
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('A', 'B', 'C')][string]$Option,
    [ValidateRange(1, 100)][int]$Count = 20,
    [ValidateRange(10, 600)][int]$IntervalSeconds = 45,
    [ValidateRange(1, 20)][int]$CutoffSample = 5,
    [ValidateRange(10, 600)][int]$CutoffSeconds = 60,
    [ValidateRange(1, 600)][int]$TargetSeconds = 20,
    [switch]$DryRun,
    [AllowNull()][object[]]$SyntheticLatency
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'SpikeLogic.psm1') -Force

$loopArgs = @{
    Count           = $Count
    IntervalSeconds = $IntervalSeconds
    CutoffSample    = $CutoffSample
    CutoffSeconds   = $CutoffSeconds
    TargetSeconds   = $TargetSeconds
}

if ($DryRun) {
    if (-not $SyntheticLatency) { throw '-DryRun requiere -SyntheticLatency (segundos por evento; $null = sin reacción).' }
    $driver = New-SyntheticDriver -Latencies $SyntheticLatency
    $result = Invoke-SpikeLoop @loopArgs -Emit $driver.Emit -Observe $driver.Observe -GetNow $driver.GetNow -Wait $driver.Wait
    $verdict = if ($result.Cut) { "No (corte $($result.Cut))" } else { 'sin corte: se completan las muestras' }
    Write-Host "[DryRun $Option] eventos emitidos: $($result.EventsSent) de $Count. Resultado: $verdict"
    return $result
}

$resultsDir = Join-Path $PSScriptRoot 'resultados'
New-Item -ItemType Directory -Force -Path $resultsDir | Out-Null
$t0File = Join-Path $resultsDir 't0.csv'
$cutFile = Join-Path $resultsDir 'cortes.csv'

function Get-RequiredEnv([string]$Name) {
    $value = [Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrWhiteSpace($value)) { throw "Falta la variable de entorno $Name (ver README)." }
    return $value
}

$siteId = Get-RequiredEnv 'SPK_SITE_ID'
Import-Module Microsoft.Graph.Sites
Connect-MgGraph -Scopes 'Sites.ReadWrite.All' -NoWelcome
$sinkListId = (Get-MgSiteList -SiteId $siteId -Filter "displayName eq 'SpikeLatencia'").Id
if (-not $sinkListId) { throw 'No existe la lista SpikeLatencia en el sitio indicado.' }

switch ($Option) {
    'A' {
        $listId = (Get-MgSiteList -SiteId $siteId -Filter "displayName eq 'SpikeEventosA'").Id
        if (-not $listId) { throw 'No existe la lista SpikeEventosA en el sitio indicado.' }
    }
    'B' {
        $dvUrl = (Get-RequiredEnv 'SPK_DV_URL').TrimEnd('/')
        $entitySet = Get-RequiredEnv 'SPK_DV_ENTITYSET'
        $dvToken = az account get-access-token --resource $dvUrl --query accessToken -o tsv
        if (-not $dvToken) { throw 'No se pudo obtener token de Dataverse con az.' }
        $dvHeaders = @{
            Authorization = "Bearer $dvToken"
            Prefer        = 'return=representation'
            Accept        = 'application/json'
        }
    }
    'C' {
        $httpUrl = Get-RequiredEnv 'SPK_HTTP_URL'
    }
}

$emit = {
    param($i)
    $eventId = [guid]::NewGuid().ToString()
    $clientUtc = [DateTime]::UtcNow
    switch ($Option) {
        'A' {
            $item = New-MgSiteListItem -SiteId $siteId -ListId $listId -BodyParameter @{
                fields = @{ Title = "Spike A $i"; EventId = $eventId }
            }
            $serverUtc = ([DateTime]$item.CreatedDateTime).ToUniversalTime()
        }
        'B' {
            # La columna se asume con nombre lógico <prefijo>_eventid; ajusta si tu prefijo es distinto.
            $prefix = $entitySet.Split('_')[0]
            $body = @{ "$($prefix)_eventid" = $eventId } | ConvertTo-Json
            $row = Invoke-RestMethod -Method Post -Uri "$dvUrl/api/data/v9.2/$entitySet" `
                -Headers $dvHeaders -ContentType 'application/json' -Body $body
            $serverUtc = ([DateTime]$row.createdon).ToUniversalTime()
        }
        'C' {
            $body = @{ eventId = $eventId } | ConvertTo-Json
            Invoke-RestMethod -Method Post -Uri $httpUrl -ContentType 'application/json' -Body $body | Out-Null
            $serverUtc = $clientUtc
        }
    }
    [pscustomobject]@{
        EventId   = $eventId
        Opcion    = $Option
        T0Utc     = $serverUtc.ToString('o')
        ClientUtc = $clientUtc.ToString('o')
    } | Export-Csv -Path $t0File -Append -NoTypeInformation
    Write-Host ("[{0}] {1}/{2} EventId={3} T0={4:HH:mm:ss}" -f $Option, $i, $Count, $eventId, $serverUtc)
    [pscustomobject]@{ EventId = $eventId; T0 = $serverUtc }
}

# Lee la lista sumidero y devuelve, por evento enviado, el tramo 2 (T2 - T0) o $null si aún no hay reacción.
$observe = {
    param($Sent)
    $byId = @{}
    Get-MgSiteListItem -SiteId $siteId -ListId $sinkListId -ExpandProperty 'fields' -All |
        ForEach-Object { $f = $_.Fields.AdditionalProperties; $byId[$f['EventId']] = $f }
    foreach ($s in $Sent) {
        $match = $byId[$s.EventId]
        $tramo2 = if ($match) { ([DateTime]::Parse($match['T2Utc']).ToUniversalTime() - $s.T0).TotalSeconds } else { $null }
        [pscustomobject]@{ EventId = $s.EventId; T0 = $s.T0; Tramo2 = $tramo2 }
    }
}

$getNow = { [DateTime]::UtcNow }
$wait = {
    param($Until)
    $ms = ($Until - [DateTime]::UtcNow).TotalMilliseconds
    if ($ms -gt 0) { Start-Sleep -Milliseconds ([int][math]::Ceiling($ms)) }
}

$result = Invoke-SpikeLoop @loopArgs -Emit $emit -Observe $observe -GetNow $getNow -Wait $wait

if ($result.Cut) {
    [pscustomobject]@{
        Opcion   = $Option
        Motivo   = $result.Cut
        Muestras = $result.EventsSent
        FechaUtc = [DateTime]::UtcNow.ToString('o')
    } | Export-Csv -Path $cutFile -Append -NoTypeInformation
    Write-Warning "Corte $($result.Cut) después de $($result.EventsSent) eventos. Opción $Option = no cumple."
}
else {
    Write-Host "Listo. $($result.EventsSent) eventos; T0 registrados en $t0File"
}
