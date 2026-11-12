#Requires -Version 7.0
<#
.SYNOPSIS
Monta la parte de Fabric de la ruta analítica de IA DAY (T-059, HU-15, CA-15.4), sin claves.

.DESCRIPTION
Con la API REST de Microsoft Fabric y la sesión de az del speaker:
1. Busca la capacidad de prueba de Fabric (o la indicada con -CapacityId).
2. Crea, si no existe, el área de trabajo de la demo en esa capacidad.
3. Crea, si no existen, el Eventhouse y el Eventstream.
4. Crea la tabla EventosNube (lo que entrega el Eventstream), la vista Eventos (eventos normalizados) y la
   tabla Historico, y carga el histórico generado por analytics/history.py.
5. Define la topología del Eventstream: fuente de punto de conexión personalizado (Microsoft Entra ID) y
   destino Eventhouse con procesamiento antes de la ingesta hacia EventosNube.
6. Si se pasa -IotHubPrincipalId, da a la identidad del IoT Hub el rol Colaborador en el área de trabajo.
7. Imprime las líneas DSA_FABRIC_* para .env que necesita infra/deploy.ps1 -EnableAnalyticsRoute.

Es idempotente. No lee, crea ni muestra ninguna clave: el IoT Hub se autentica con su identidad
administrada (https://learn.microsoft.com/azure/iot-hub/iot-hub-devguide-endpoints#custom-endpoints-for-message-routing).

API: https://learn.microsoft.com/rest/api/fabric/core/workspaces/create-workspace
     https://learn.microsoft.com/fabric/real-time-intelligence/event-streams/eventstream-rest-api

.EXAMPLE
./analytics/fabric-setup.ps1
./analytics/fabric-setup.ps1 -IotHubPrincipalId <object ID que imprime infra/deploy.ps1>
#>
[CmdletBinding()]
param(
    [string] $WorkspaceName = 'DSA IA Day',
    [string] $EventhouseName = 'eh-dsa',
    [string] $EventstreamName = 'es-dsa-eventos',
    [string] $CapacityId = '',
    [string] $IotHubPrincipalId = '',
    [string] $HistoryCsv = (Join-Path $PSScriptRoot 'out/historico.csv')
)

$ErrorActionPreference = 'Stop'
$api = 'https://api.fabric.microsoft.com/v1'
$sourceName = 'iothub-ruta'
$destinationName = 'eventhouse-nube'

function Get-FabricHeaders {
    $token = az account get-access-token --resource https://api.fabric.microsoft.com --query accessToken -o tsv
    if ($LASTEXITCODE -ne 0 -or -not $token) { throw 'No hay sesión de az: ejecuta az login con la cuenta del speaker.' }
    return @{ Authorization = "Bearer $token"; 'Content-Type' = 'application/json' }
}

function Wait-FabricItem {
    # La creación de algunos elementos es asíncrona (202): espera a que aparezcan en la lista.
    param([string] $WorkspaceId, [string] $Type, [string] $Name, [hashtable] $Headers)
    for ($i = 0; $i -lt 30; $i++) {
        $item = (Invoke-RestMethod -Headers $Headers "$api/workspaces/$WorkspaceId/items?type=$Type").value |
            Where-Object displayName -eq $Name
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

function ConvertTo-Base64 {
    param([string] $Text)
    return [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Text))
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
$eventstream = Get-OrCreateFabricItem -WorkspaceId $workspace.id -Type 'Eventstream' -Path 'eventstreams' -Name $EventstreamName -Headers $headers

# 4. Tablas KQL
$queryUri = (Invoke-RestMethod -Headers $headers "$api/workspaces/$($workspace.id)/eventhouses/$($eventhouse.id)").properties.queryServiceUri
$database = (Invoke-RestMethod -Headers $headers "$api/workspaces/$($workspace.id)/kqlDatabases").value |
    Where-Object displayName -eq $EventhouseName | Select-Object -First 1
if (-not $database) { throw "No se encontró la base KQL '$EventhouseName' del Eventhouse." }
$db = $database.displayName

# EventosNube: lo que escribe el Eventstream (campos del evento más los metadatos del Eventstream).
Invoke-KqlCommand -QueryUri $queryUri -Database $db -Command (
    '.create-merge table EventosNube (schemaVersion:string, eventId:string, deviceId:string, type:string, ' +
    'zone:string, timestamp:string, rawSeverity:string, EventProcessedUtcTime:datetime, PartitionId:long, ' +
    'EventEnqueuedUtcTime:datetime)')
# Eventos: vista (función sin parámetros) con el evento del dispositivo normalizado
# (schemas/evento-dispositivo.schema.json). Es una vista y no una tabla con política de actualización porque
# la ingesta del Eventstream no dispara las políticas de actualización.
Invoke-KqlCommand -QueryUri $queryUri -Database $db -Command '.drop table Eventos ifexists'
Invoke-KqlCommand -QueryUri $queryUri -Database $db -Command (
    ".create-or-alter function with (docstring = 'Vista de los eventos del dispositivo normalizados desde EventosNube (T-059)') " +
    'Eventos() { EventosNube | project schemaVersion, eventId, deviceId, type, zone, ' +
    'timestamp = todatetime(timestamp), rawSeverity }')
Write-Host '[listo]   tabla EventosNube y vista Eventos'

Invoke-KqlCommand -QueryUri $queryUri -Database $db -Command (
    '.create-merge table Historico (eventId:string, fechaUtc:datetime, horaLocal:string, zona:string, ' +
    'nombreZona:string, sitio:string, tipoEvento:string, severidadInicial:string, severidadPropuesta:string, ' +
    'fueraDeHorario:bool, repeticiones:int, decision:string, decididoPor:string, minutosHastaDecision:int, estado:string)')
if (Test-Path -LiteralPath $HistoryCsv) {
    $rows = Get-Content -LiteralPath $HistoryCsv -Encoding utf8 | Select-Object -Skip 1
    Invoke-KqlCommand -QueryUri $queryUri -Database $db -Command '.clear table Historico data'
    Invoke-KqlCommand -QueryUri $queryUri -Database $db -Command (
        ".ingest inline into table Historico with (format='csv') <|`n" + ($rows -join "`n"))
    Write-Host "[cargado] $($rows.Count) incidentes ficticios en Historico"
}
else {
    Write-Host "[omitido] histórico: genera primero $HistoryCsv con python -m analytics.history"
}

# 5. Topología del Eventstream
$esUri = "$api/workspaces/$($workspace.id)/eventstreams/$($eventstream.id)"
$current = $null
try { $current = Invoke-RestMethod -Headers $headers "$esUri/topology" } catch { $current = $null }
$hasSource = $current -and ($current.sources | Where-Object name -eq $sourceName)
$hasDestination = $current -and ($current.destinations | Where-Object name -eq $destinationName)
if ($hasSource -and $hasDestination) {
    Write-Host "[existe]  topología del Eventstream"
}
else {
    $topology = @{
        sources      = @(@{ name = $sourceName; type = 'CustomEndpoint'; properties = @{} })
        destinations = @(@{
                name       = $destinationName
                type       = 'Eventhouse'
                # ProcessedIngestion: el Eventstream gestiona la ingesta (Learn, Eventstream REST API).
                properties = @{
                    dataIngestionMode  = 'ProcessedIngestion'
                    workspaceId        = $workspace.id
                    itemId             = $database.id
                    databaseName       = $db
                    tableName          = 'EventosNube'
                    inputSerialization = @{ type = 'Json'; properties = @{ encoding = 'UTF8' } }
                }
                inputNodes = @(@{ name = "$EventstreamName-stream" })
            })
        streams      = @(@{ name = "$EventstreamName-stream"; type = 'DefaultStream'; properties = @{}; inputNodes = @(@{ name = $sourceName }) })
        operators    = @()
        compatibilityLevel = '1.1'
    } | ConvertTo-Json -Depth 10
    $platform = @{
        '$schema' = 'https://developer.microsoft.com/json-schemas/fabric/gitIntegration/platformProperties/2.0.0/schema.json'
        metadata  = @{ type = 'Eventstream'; displayName = $EventstreamName }
        config    = @{ version = '2.0'; logicalId = '00000000-0000-0000-0000-000000000000' }
    } | ConvertTo-Json -Depth 5
    $body = @{ definition = @{ parts = @(
                @{ path = 'eventstream.json'; payload = (ConvertTo-Base64 $topology); payloadType = 'InlineBase64' }
                @{ path = '.platform'; payload = (ConvertTo-Base64 $platform); payloadType = 'InlineBase64' }
            ) } } | ConvertTo-Json -Depth 6
    Invoke-RestMethod -Method Post -Headers $headers -Body $body "$esUri/updateDefinition" | Out-Null
    Write-Host '[creado]  topología: punto de conexión personalizado -> Eventhouse (EventosNube)'
}

# 6. Identidad del IoT Hub como Colaborador del área de trabajo
if ($IotHubPrincipalId) {
    $assigned = (Invoke-RestMethod -Headers $headers "$api/workspaces/$($workspace.id)/roleAssignments").value |
        Where-Object { $_.principal.id -eq $IotHubPrincipalId }
    if ($assigned) {
        Write-Host '[existe]  rol de la identidad del IoT Hub en el área de trabajo'
    }
    else {
        $body = @{ principal = @{ id = $IotHubPrincipalId; type = 'ServicePrincipal' }; role = 'Contributor' } | ConvertTo-Json
        Invoke-RestMethod -Method Post -Headers $headers -Body $body "$api/workspaces/$($workspace.id)/roleAssignments" | Out-Null
        Write-Host '[creado]  identidad del IoT Hub como Colaborador del área de trabajo'
    }
}

# 7. Datos del punto de conexión para .env (solo los de Entra ID; las claves SAS que la API también
#    devuelve no se leen ni se muestran).
$source = $null
for ($i = 0; $i -lt 30 -and -not $source; $i++) {
    $source = (Invoke-RestMethod -Headers $headers "$esUri/topology").sources |
        Where-Object { $_.name -eq $sourceName -and $_.status -eq 'Running' }
    if (-not $source) { Start-Sleep -Seconds 10 }
}
if (-not $source) { throw 'La fuente del Eventstream no quedó en ejecución después de 5 minutos.' }
$connection = Invoke-RestMethod -Headers $headers "$esUri/sources/$($source.id)/connection"

Write-Host ''
Write-Host 'Agrega estas líneas a .env (identificadores, no secretos) y despliega con infra/deploy.ps1 -EnableAnalyticsRoute:'
Write-Host "DSA_FABRIC_ENDPOINT_URI=sb://$($connection.fullyQualifiedNamespace)"
Write-Host "DSA_FABRIC_ENTITY_PATH=$($connection.eventHubName)"
Write-Host "DSA_FABRIC_WORKSPACE_ID=$($workspace.id)"
Write-Host "DSA_FABRIC_EVENTSTREAM_ID=$($eventstream.id)"
Write-Host "DSA_FABRIC_SOURCE_ID=$($source.id)"
