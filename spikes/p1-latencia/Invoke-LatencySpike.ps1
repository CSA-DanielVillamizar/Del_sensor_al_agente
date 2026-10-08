#Requires -Version 7.0
<#
.SYNOPSIS
    SPK-01: emite N eventos de prueba por la opción A (SharePoint), B (Dataverse) o C (HTTP) y registra T0.
.DESCRIPTION
    Código desechable del spike de latencia. Las credenciales se obtienen con identidad delegada
    (Connect-MgGraph y az login); ninguna URL ni secreto se escribe en disco.

    Condición de corte: después del evento número CutoffSample, el script espera CutoffSeconds
    y revisa la lista SpikeLatencia. Si ninguno de esos primeros eventos tiene el tramo 2 completo
    en CutoffSeconds o menos, detiene la opción y la registra en resultados/cortes.csv.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('A', 'B', 'C')][string]$Option,
    [ValidateRange(1, 100)][int]$Count = 20,
    [ValidateRange(10, 600)][int]$IntervalSeconds = 45,
    [ValidateRange(1, 20)][int]$CutoffSample = 5,
    [ValidateRange(10, 600)][int]$CutoffSeconds = 60
)

$ErrorActionPreference = 'Stop'
$resultsDir = Join-Path $PSScriptRoot 'resultados'
New-Item -ItemType Directory -Force -Path $resultsDir | Out-Null
$t0File = Join-Path $resultsDir 't0.csv'
$cutFile = Join-Path $resultsDir 'cortes.csv'

function Get-RequiredEnv([string]$Name) {
    $value = [Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrWhiteSpace($value)) { throw "Falta la variable de entorno $Name (ver README)." }
    return $value
}

# Devuelve, por EventId, los segundos del tramo 2 (T2 - T0) que ya están en la lista sumidero.
function Get-Tramo2([object[]]$Sent) {
    $items = Get-MgSiteListItem -SiteId $siteId -ListId $sinkListId -ExpandProperty 'fields' -All |
        ForEach-Object { $_.Fields.AdditionalProperties }
    $byId = @{}
    foreach ($fields in $items) { $byId[$fields['EventId']] = $fields }
    foreach ($s in $Sent) {
        $match = $byId[$s.EventId]
        [pscustomobject]@{
            EventId = $s.EventId
            Tramo2  = if ($match) { ([DateTime]::Parse($match['T2Utc']).ToUniversalTime() - $s.T0).TotalSeconds } else { $null }
        }
    }
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

$sent = [System.Collections.Generic.List[object]]::new()

for ($i = 1; $i -le $Count; $i++) {
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

    $sent.Add([pscustomobject]@{ EventId = $eventId; T0 = $serverUtc })
    [pscustomobject]@{
        EventId   = $eventId
        Opcion    = $Option
        T0Utc     = $serverUtc.ToString('o')
        ClientUtc = $clientUtc.ToString('o')
    } | Export-Csv -Path $t0File -Append -NoTypeInformation

    Write-Host ("[{0}] {1}/{2} EventId={3} T0={4:HH:mm:ss}" -f $Option, $i, $Count, $eventId, $serverUtc)

    if ($i -eq $CutoffSample -and $i -lt $Count) {
        $waitUntil = $serverUtc.AddSeconds($CutoffSeconds)
        $remaining = ($waitUntil - [DateTime]::UtcNow).TotalSeconds
        if ($remaining -gt 0) { Start-Sleep -Seconds ([math]::Ceiling($remaining)) }

        $within = @(Get-Tramo2 $sent | Where-Object { $null -ne $_.Tramo2 -and $_.Tramo2 -le $CutoffSeconds })
        if ($within.Count -eq 0) {
            [pscustomobject]@{
                Opcion     = $Option
                Muestras   = $i
                UmbralSeg  = $CutoffSeconds
                FechaUtc   = [DateTime]::UtcNow.ToString('o')
            } | Export-Csv -Path $cutFile -Append -NoTypeInformation
            Write-Warning "Corte: ninguno de los primeros $i eventos completó el tramo 2 en $CutoffSeconds s. Opción $Option = no cumple."
            return
        }
        Write-Host "Control de corte superado: $($within.Count) de $i eventos en <= $CutoffSeconds s. Se continúa."
        continue
    }

    if ($i -lt $Count) { Start-Sleep -Seconds $IntervalSeconds }
}

Write-Host "Listo. T0 registrados en $t0File"
