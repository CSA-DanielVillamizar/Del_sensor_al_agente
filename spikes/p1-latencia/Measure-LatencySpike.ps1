#Requires -Version 7.0
<#
.SYNOPSIS
    SPK-01: cruza T0 (t0.csv) con T1/T2 (lista SpikeLatencia) y calcula p50, p90 y máximo por opción.
    Los eventos sin reacción al vencer el tiempo de espera entran al cálculo como "sin reacción" (+Infinito).
#>
[CmdletBinding()]
param(
    [ValidateRange(1, 60)][int]$TimeoutMinutes = 10,
    [ValidateRange(1, 600)][int]$TargetSeconds = 20
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'SpikeLogic.psm1') -Force

$resultsDir = Join-Path $PSScriptRoot 'resultados'
$t0File = Join-Path $resultsDir 't0.csv'
if (-not (Test-Path $t0File)) { throw "No existe $t0File. Ejecuta primero Invoke-LatencySpike.ps1." }

$siteId = [Environment]::GetEnvironmentVariable('SPK_SITE_ID')
if (-not $siteId) { throw 'Falta la variable de entorno SPK_SITE_ID.' }

Import-Module Microsoft.Graph.Sites
Connect-MgGraph -Scopes 'Sites.Read.All' -NoWelcome
$listId = (Get-MgSiteList -SiteId $siteId -Filter "displayName eq 'SpikeLatencia'").Id
$sink = @{}
Get-MgSiteListItem -SiteId $siteId -ListId $listId -ExpandProperty 'fields' -All |
    ForEach-Object { $f = $_.Fields.AdditionalProperties; $sink[$f['EventId']] = $f }

$cutFile = Join-Path $resultsDir 'cortes.csv'
$cuts = @{}
if (Test-Path $cutFile) { Import-Csv $cutFile | ForEach-Object { $cuts[$_.Opcion] = $_.Motivo } }

$now = [DateTime]::UtcNow
$rows = Import-Csv $t0File | ForEach-Object {
    $t0 = [DateTime]::Parse($_.T0Utc).ToUniversalTime()
    $match = $sink[$_.EventId]
    [pscustomobject]@{
        Opcion   = $_.Opcion
        EventId  = $_.EventId
        Reaccion = if ($match) { ([DateTime]::Parse($match['T1Utc']).ToUniversalTime() - $t0).TotalSeconds } else { $null }
        Tramo2   = if ($match) { ([DateTime]::Parse($match['T2Utc']).ToUniversalTime() - $t0).TotalSeconds } else { $null }
        Vencido  = (-not $match) -and (($now - $t0).TotalMinutes -ge $TimeoutMinutes)
    }
}

$summary = @(Get-SpikeSummary -Rows $rows -Cuts $cuts -TargetSeconds $TargetSeconds)
$lines = ConvertTo-SpikeMarkdown -Summary $summary -GeneratedUtc $now -TargetSeconds $TargetSeconds

$summaryFile = Join-Path $resultsDir 'resumen.md'
$lines | Set-Content -Path $summaryFile -Encoding utf8
$lines | Write-Host
