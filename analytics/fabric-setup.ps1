#Requires -Version 7.0
<#
.SYNOPSIS
Monta la parte de Fabric de la ruta analítica de IA DAY (T-059, HU-15, CA-15.4).

.DESCRIPTION
Con la API REST de Microsoft Fabric y la sesión de az del speaker:
1. Busca la capacidad de prueba de Fabric (o la indicada con -CapacityId).
2. Crea, si no existe, el área de trabajo de la demo en esa capacidad.
3. Crea, si no existen, el Eventhouse y el Eventstream vacío.
4. Crea las tablas Eventos (eventos crudos) e Historico (incidentes ficticios) en la base KQL
   y carga el histórico generado por analytics/history.py.

Es idempotente: si algo ya existe, lo reutiliza. No crea la fuente IoT Hub del Eventstream: esa
conexión necesita la clave de la política fabric-reader y la configura el speaker a mano, fuera
de cámara, siguiendo analytics/README.md. Este script nunca lee ni muestra claves.

API: https://learn.microsoft.com/rest/api/fabric/core/workspaces/create-workspace
     https://learn.microsoft.com/rest/api/fabric/eventhouse/items/create-eventhouse
     https://learn.microsoft.com/rest/api/fabric/eventstream/items/create-eventstream

.EXAMPLE
./analytics/fabric-setup.ps1
./analytics/fabric-setup.ps1 -WorkspaceName 'DSA IA Day' -HistoryCsv analytics/out/historico.csv
#>
[CmdletBinding()]
param(
    [string] $WorkspaceName = 'DSA IA Day',
    [string] $EventhouseName = 'eh-dsa',
    [string] $EventstreamName = 'es-dsa-eventos',
    [string] $CapacityId = '',
    [string] $HistoryCsv = (Join-Path $PSScriptRoot 'out/historico.csv')
)

$ErrorActionPreference = 'Stop'
$api = 'https://api.fabric.microsoft.com/v1'

function Get-FabricHeaders {
    $token = az account get-access-token --resource https://api.fabric.microsoft.com --query accessToken -o tsv
    if ($LASTEXITCODE -ne 0 -or -not $token) { throw 'No hay sesión de az: ejecuta az login con la cuenta del speaker.' }
    return @{ Authorization = "Bearer $token"; 'Content-Type' = 'application/json' }
}

function Wait-FabricItem {
    # La creación de algunos elementos es asíncrona (202): espera a que aparezcan en la lista.
    param([string] $WorkspaceId, [string] $Type, [string] $Name, [hashtable] $Headers)
    for ($i = 0; $i -lt 30; $i++) {
        $items = (Invoke-RestMethod -Headers $Headers "$api/workspaces/$WorkspaceId/items?type=$Type").value
        $item = $items | Where-Object displayName -eq $Name
        if ($item) { return $item }
        Start-Sleep -Seconds 5
    }
    throw "No apareció $Type '$Name' después de 150 s."
}

function Get-OrCreateFabricItem {
    param([string] $WorkspaceId, [string] $Type, [string] $Path, [string] $Name, [hashtable] $Headers)
    $existing = (Invoke-RestMethod -Headers $Headers "$api/workspaces/$WorkspaceId/items?type=$Type").value |
        Where-Object displayName -eq $Name
    if ($existing) { Write-Host "[existe]  $Type '$Name'"; return $existing }
    $body = @{ displayName = $Name; description = 'Demo IA DAY (datos ficticios)' } | ConvertTo-Json
    Invoke-RestMethod -Method Post -Headers $Headers -Body $body "$api/workspaces/$WorkspaceId/$Path" | Out-Null
    $item = Wait-FabricItem -WorkspaceId $WorkspaceId -Type $Type -Name $Name -Headers $Headers
    Write-Host "[creado]  $Type '$Name'"
    return $item
}

function Invoke-KqlCommand {
    param([string] $QueryUri, [string] $Database, [string] $Command)
    $token = az account get-access-token --resource https://kusto.kusto.windows.net --query accessToken -o tsv
    $headers = @{ Authorization = "Bearer $token"; 'Content-Type' = 'application/json' }
    $body = @{ db = $Database; csl = $Command } | ConvertTo-Json
    Invoke-RestMethod -Method Post -Headers $headers -Body $body "$QueryUri/v1/rest/mgmt" | Out-Null
}

$headers = Get-FabricHeaders

# 1. Capacidad
if (-not $CapacityId) {
    $capacity = (Invoke-RestMethod -Headers $headers "$api/capacities").value |
        Where-Object { $_.sku -like 'FT*' -and $_.state -eq 'Active' } | Select-Object -First 1
    if (-not $capacity) { throw 'No hay una capacidad de prueba de Fabric activa. Actívala desde el administrador de cuentas de Fabric.' }
    $CapacityId = $capacity.id
    Write-Host "Capacidad de prueba: $($capacity.displayName) ($($capacity.region))"
}

# 2. Área de trabajo
$workspace = (Invoke-RestMethod -Headers $headers "$api/workspaces").value | Where-Object displayName -eq $WorkspaceName
if ($workspace) {
    Write-Host "[existe]  área de trabajo '$WorkspaceName'"
}
else {
    $body = @{ displayName = $WorkspaceName; capacityId = $CapacityId; description = 'Demo IA DAY: ruta analítica con datos ficticios.' } | ConvertTo-Json
    $workspace = Invoke-RestMethod -Method Post -Headers $headers -Body $body "$api/workspaces"
    Write-Host "[creado]  área de trabajo '$WorkspaceName'"
}

# 3. Eventhouse y Eventstream
$eventhouse = Get-OrCreateFabricItem -WorkspaceId $workspace.id -Type 'Eventhouse' -Path 'eventhouses' -Name $EventhouseName -Headers $headers
Get-OrCreateFabricItem -WorkspaceId $workspace.id -Type 'Eventstream' -Path 'eventstreams' -Name $EventstreamName -Headers $headers | Out-Null

# 4. Tablas KQL
$details = Invoke-RestMethod -Headers $headers "$api/workspaces/$($workspace.id)/eventhouses/$($eventhouse.id)"
$queryUri = $details.properties.queryServiceUri
$database = (Invoke-RestMethod -Headers $headers "$api/workspaces/$($workspace.id)/items?type=KQLDatabase").value |
    Where-Object displayName -eq $EventhouseName | Select-Object -First 1
if (-not $database) { throw "No se encontró la base KQL '$EventhouseName' del Eventhouse." }

# Eventos: un evento crudo del dispositivo, tal como lo entrega IoT Hub (schemas/evento-dispositivo.schema.json).
Invoke-KqlCommand -QueryUri $queryUri -Database $database.displayName -Command (
    '.create-merge table Eventos (schemaVersion:string, eventId:string, deviceId:string, type:string, ' +
    'zone:string, timestamp:datetime, rawSeverity:string)')
Write-Host '[listo]   tabla Eventos'

Invoke-KqlCommand -QueryUri $queryUri -Database $database.displayName -Command (
    '.create-merge table Historico (eventId:string, fechaUtc:datetime, horaLocal:string, zona:string, ' +
    'nombreZona:string, sitio:string, tipoEvento:string, severidadInicial:string, severidadPropuesta:string, ' +
    'fueraDeHorario:bool, repeticiones:int, decision:string, decididoPor:string, minutosHastaDecision:int, estado:string)')
Write-Host '[listo]   tabla Historico'

if (Test-Path -LiteralPath $HistoryCsv) {
    $rows = Get-Content -LiteralPath $HistoryCsv -Encoding utf8 | Select-Object -Skip 1
    Invoke-KqlCommand -QueryUri $queryUri -Database $database.displayName -Command '.clear table Historico data'
    $inline = ".ingest inline into table Historico with (format='csv') <|`n" + ($rows -join "`n")
    Invoke-KqlCommand -QueryUri $queryUri -Database $database.displayName -Command $inline
    Write-Host "[cargado] $($rows.Count) incidentes ficticios en Historico"
}
else {
    Write-Host "[omitido] histórico: genera primero $HistoryCsv con python -m analytics.history"
}

Write-Host ''
Write-Host "Área de trabajo: $WorkspaceName"
Write-Host "Base KQL:        $($database.displayName)"
Write-Host 'Siguiente paso:  conectar la fuente IoT Hub del Eventstream (analytics/README.md, paso 3).'
