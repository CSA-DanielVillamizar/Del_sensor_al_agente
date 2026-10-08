#Requires -Version 7.0
<#
.SYNOPSIS
    SPK-01: cruza T0 (t0.csv) con T1/T2 (lista SpikeLatencia) y calcula p50, p90 y máximo por opción.
#>
[CmdletBinding()]
param(
    [ValidateRange(1, 60)][int]$TimeoutMinutes = 10
)

$ErrorActionPreference = 'Stop'
$resultsDir = Join-Path $PSScriptRoot 'resultados'
$t0File = Join-Path $resultsDir 't0.csv'
if (-not (Test-Path $t0File)) { throw "No existe $t0File. Ejecuta primero Invoke-LatencySpike.ps1." }

$siteId = [Environment]::GetEnvironmentVariable('SPK_SITE_ID')
if (-not $siteId) { throw 'Falta la variable de entorno SPK_SITE_ID.' }

Import-Module Microsoft.Graph.Sites
Connect-MgGraph -Scopes 'Sites.Read.All' -NoWelcome
$listId = (Get-MgSiteList -SiteId $siteId -Filter "displayName eq 'SpikeLatencia'").Id
$sink = Get-MgSiteListItem -SiteId $siteId -ListId $listId -ExpandProperty 'fields' -All |
    ForEach-Object { $_.Fields.AdditionalProperties } |
    Group-Object { $_['EventId'] } -AsHashTable -AsString

# Percentil por rango más cercano.
function Get-Percentile([double[]]$Values, [double]$P) {
    $sorted = $Values | Sort-Object
    $rank = [math]::Ceiling($P / 100 * $sorted.Count)
    return $sorted[[math]::Max(0, $rank - 1)]
}

$cutFile = Join-Path $resultsDir 'cortes.csv'
$cutOptions = if (Test-Path $cutFile) { @(Import-Csv $cutFile | ForEach-Object Opcion) } else { @() }

$now = [DateTime]::UtcNow
$rows = Import-Csv $t0File | ForEach-Object {
    $t0 = [DateTime]::Parse($_.T0Utc).ToUniversalTime()
    $match = if ($sink -and $sink.ContainsKey($_.EventId)) { $sink[$_.EventId][0] } else { $null }
    [pscustomobject]@{
        Opcion  = $_.Opcion
        EventId = $_.EventId
        Reaccion = if ($match) { ([DateTime]::Parse($match['T1Utc']).ToUniversalTime() - $t0).TotalSeconds } else { $null }
        Tramo2  = if ($match) { ([DateTime]::Parse($match['T2Utc']).ToUniversalTime() - $t0).TotalSeconds } else { $null }
        Vencido = (-not $match) -and (($now - $t0).TotalMinutes -ge $TimeoutMinutes)
    }
}

$lines = @(
    '# SPK-01 - Resultados',
    '',
    "Generado: $($now.ToString('yyyy-MM-dd HH:mm')) UTC. Umbral de decisión: p90 del tramo 2 <= 20 s.",
    '',
    '| Opción | n | Sin reacción | Reacción p50 | Reacción p90 | Tramo 2 p50 | Tramo 2 p90 | Tramo 2 máx | ¿Cumple? |',
    '| --- | --- | --- | --- | --- | --- | --- | --- | --- |'
)
foreach ($group in $rows | Group-Object Opcion | Sort-Object Name) {
    $ok = @($group.Group | Where-Object { $null -ne $_.Tramo2 })
    $failed = @($group.Group | Where-Object Vencido).Count
    if ($ok.Count -eq 0) {
        $verdict = if ($cutOptions -contains $group.Name) { 'No (corte)' } else { 'No' }
        $lines += "| $($group.Name) | $($group.Count) | $failed | - | - | - | - | - | $verdict |"
        continue
    }
    $r = [double[]]$ok.Reaccion
    $t = [double[]]$ok.Tramo2
    $p90 = Get-Percentile $t 90
    $meets = if ($cutOptions -contains $group.Name) { 'No (corte)' }
             elseif ($failed -eq 0 -and $p90 -le 20) { 'Sí' }
             else { 'No' }
    $lines += ('| {0} | {1} | {2} | {3:N1} s | {4:N1} s | {5:N1} s | {6:N1} s | {7:N1} s | {8} |' -f
        $group.Name, $group.Count, $failed, (Get-Percentile $r 50), (Get-Percentile $r 90),
        (Get-Percentile $t 50), $p90, ($t | Measure-Object -Maximum).Maximum, $meets)
}

$pending = @($rows | Where-Object { $null -eq $_.Tramo2 -and -not $_.Vencido }).Count
if ($pending -gt 0) { $lines += '', "Atención: $pending eventos aún dentro del tiempo de espera; vuelve a ejecutar más tarde." }

$summary = Join-Path $resultsDir 'resumen.md'
$lines | Set-Content -Path $summary -Encoding utf8
$lines | Write-Host
