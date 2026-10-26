#Requires -Version 7.0
<#
    T-046 (HU-14 CA-14.2) y T-048 (HU-14, ADR-004): lógica pura de demo/reset.ps1 y demo/retrigger.ps1.
    Sin Graph, sin Azure y sin red: los scripts obtienen los datos y este módulo filtra, arma URIs y
    cuerpos. Reutiliza sharepoint/ProvisionLogic.psm1 para .env, el sitio y la paginación.

    Referencias:
    - Delete Entity (Table Storage): https://learn.microsoft.com/rest/api/storageservices/delete-entity1
    - Claves de entidad en la URI: https://learn.microsoft.com/rest/api/storageservices/understanding-the-table-service-data-model#characters-disallowed-in-key-fields
    - Filtro por columna en Graph: https://learn.microsoft.com/graph/api/listitem-list#example-3-list-items-with-filtering
#>

Set-StrictMode -Version 3.0
Import-Module (Join-Path $PSScriptRoot '..' 'sharepoint' 'ProvisionLogic.psm1') -Force -Global

# Mismo patrón que schemas/evento-dispositivo.schema.json: UUID en minúsculas, versiones 1 a 8.
$script:EventIdPattern = '^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'

# Tablas de ADR-006 que vacía demo/reset.
$script:ResetTables = @('dedup', 'ratelimit')

# --- Elementos de la lista ----------------------------------------------------------------------

# Interpreta el valor de EsPrueba que devuelve Graph (booleano) o una exportación (texto).
function ConvertTo-DsaBoolean {
    param([AllowNull()][object] $Value)
    if ($null -eq $Value) { return $false }
    if ($Value -is [bool]) { return $Value }
    $text = ([string]$Value).Trim().ToLowerInvariant()
    return @('true', '1', 'sí', 'si', 'yes') -contains $text
}

<#
    Elige los elementos que reset manda a la papelera. $Items: listItems de Graph con 'fields'.
    Sin -All, solo los que tienen EsPrueba = Sí (CA-14.2). Devuelve Id, EventId, Estado y EsPrueba.
#>
function Select-DsaResetItems {
    param(
        [AllowNull()][AllowEmptyCollection()][object[]] $Items,
        [switch] $All
    )
    $selected = foreach ($item in @($Items | Where-Object { $null -ne $_ })) {
        $fields = Get-DsaValue $item 'fields'
        $isTest = ConvertTo-DsaBoolean (Get-DsaValue $fields 'EsPrueba')
        if (-not $All -and -not $isTest) { continue }
        [pscustomobject]@{
            Id       = [string](Get-DsaValue $item 'id')
            EventId  = [string](Get-DsaValue $fields 'EventId')
            Estado   = [string](Get-DsaValue $fields 'Estado')
            EsPrueba = $isTest
        }
    }
    return , @($selected)
}

# --- Table Storage ------------------------------------------------------------------------------

function Get-DsaResetTables { return $script:ResetTables }

# Escapa un valor de clave para la URI de una entidad: comillas simples dobladas (OData) y codificación
# de porcentaje. Necesario porque la PartitionKey de dedup lleva '|' (ADR-006).
function ConvertTo-DsaODataKey {
    param([Parameter(Mandatory)][AllowEmptyString()][string] $Value)
    return [uri]::EscapeDataString($Value.Replace("'", "''"))
}

# URI de una entidad: https://{cuenta}.table.core.windows.net/{tabla}(PartitionKey='..',RowKey='..').
function Get-DsaTableEntityUri {
    param(
        [Parameter(Mandatory)][ValidatePattern('^[a-z0-9]{3,24}$')][string] $Account,
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z][A-Za-z0-9]{2,62}$')][string] $Table,
        [Parameter(Mandatory)][AllowEmptyString()][string] $PartitionKey,
        [Parameter(Mandatory)][AllowEmptyString()][string] $RowKey
    )
    $pk = ConvertTo-DsaODataKey $PartitionKey
    $rk = ConvertTo-DsaODataKey $RowKey
    return "https://$Account.table.core.windows.net/$Table(PartitionKey='$pk',RowKey='$rk')"
}

# Convierte la salida JSON de 'az storage entity query' en { Entities = PK/RK; Marker = $null | hashtable }.
function ConvertFrom-DsaEntityQuery {
    param([Parameter(Mandatory)][AllowEmptyString()][string] $Json)
    if ([string]::IsNullOrWhiteSpace($Json)) { return [pscustomobject]@{ Entities = @(); Marker = $null } }
    $parsed = $Json | ConvertFrom-Json -AsHashtable -NoEnumerate
    $rows = if ($parsed -is [System.Collections.IDictionary]) { @($parsed['items']) } else { @($parsed) }
    $entities = @(
        $rows | Where-Object { $null -ne $_ } | ForEach-Object {
            [pscustomobject]@{ PartitionKey = [string]$_['PartitionKey']; RowKey = [string]$_['RowKey'] }
        }
    )
    $marker = $null
    if ($parsed -is [System.Collections.IDictionary] -and $parsed['nextMarker'] -is [System.Collections.IDictionary]) {
        $next = $parsed['nextMarker']
        if ($next['nextpartitionkey'] -or $next['nextrowkey']) {
            $marker = @{ nextpartitionkey = [string]$next['nextpartitionkey']; nextrowkey = [string]$next['nextrowkey'] }
        }
    }
    return [pscustomobject]@{ Entities = $entities; Marker = $marker }
}

# Argumentos de 'az storage entity query' (identidad de Daniel con --auth-mode login).
function Get-DsaEntityQueryArguments {
    param(
        [Parameter(Mandatory)][string] $Account,
        [Parameter(Mandatory)][string] $Table,
        [AllowNull()][hashtable] $Marker
    )
    $arguments = @(
        'storage', 'entity', 'query',
        '--account-name', $Account, '--table-name', $Table, '--auth-mode', 'login',
        '--select', 'PartitionKey', 'RowKey', '--num-results', '1000', '--output', 'json'
    )
    if ($Marker) {
        $arguments += @('--marker', "nextpartitionkey=$($Marker.nextpartitionkey)", "nextrowkey=$($Marker.nextrowkey)")
    }
    return , $arguments
}

# Cabeceras de Delete Entity con token de Microsoft Entra ID (x-ms-version admite OAuth en tablas).
function Get-DsaTableDeleteHeaders {
    param([Parameter(Mandatory)][string] $AccessToken, [datetime] $UtcNow = [datetime]::UtcNow)
    return @{
        Authorization  = "Bearer $AccessToken"
        'x-ms-version' = '2020-12-06'
        'x-ms-date'    = $UtcNow.ToString('R', [cultureinfo]::InvariantCulture)
        'If-Match'     = '*'
        Accept         = 'application/json;odata=nometadata'
    }
}

# --- Tiempo -------------------------------------------------------------------------------------

# Resultado del cronómetro frente al objetivo de CA-14.2 (≤ 2 min).
function Format-DsaElapsed {
    param([Parameter(Mandatory)][timespan] $Elapsed, [timespan] $Target = [timespan]::FromMinutes(2))
    $ok = $Elapsed -le $Target
    $text = '{0:mm\:ss\.f} (objetivo ≤ {1:mm\:ss})' -f $Elapsed, $Target
    return [pscustomobject]@{ Text = $text; WithinTarget = $ok; Color = if ($ok) { 'Green' } else { 'Yellow' } }
}

# --- Retrigger ----------------------------------------------------------------------------------

function Test-DsaEventId {
    param([AllowNull()][AllowEmptyString()][string] $EventId)
    return (-not [string]::IsNullOrEmpty($EventId)) -and ($EventId -cmatch $script:EventIdPattern)
}

# Consulta de Graph del elemento por EventId (columna indexada, §4.3). El EventId ya viene validado,
# así que no puede inyectar nada en el filtro.
function Get-DsaItemByEventIdUri {
    param(
        [Parameter(Mandatory)][string] $SiteId,
        [Parameter(Mandatory)][string] $ListId,
        [Parameter(Mandatory)][string] $EventId
    )
    if (-not (Test-DsaEventId $EventId)) { throw "EventId no válido: '$EventId'" }
    $filter = [uri]::EscapeDataString("fields/EventId eq '$EventId'")
    return "v1.0/sites/$SiteId/lists/$ListId/items?`$filter=$filter&`$expand=fields(`$select=EventId,Estado,EsPrueba)&`$select=id"
}

<#
    Decide si se vuelve a llamar al flujo. Solo si hay exactamente un elemento y sigue en 'Nuevo'
    (ADR-004 §2). Devuelve Action = Trigger | Skip | NotFound | Ambiguous y el motivo.
#>
function Get-DsaRetriggerDecision {
    param([AllowNull()][AllowEmptyCollection()][object[]] $Items)
    $found = @($Items | Where-Object { $null -ne $_ })
    if ($found.Count -eq 0) { return [pscustomobject]@{ Action = 'NotFound'; Estado = $null; Reason = 'no hay ningún elemento con ese EventId' } }
    if ($found.Count -gt 1) { return [pscustomobject]@{ Action = 'Ambiguous'; Estado = $null; Reason = "hay $($found.Count) elementos con ese EventId (revisar la unicidad, R-14)" } }
    $estado = [string](Get-DsaValue (Get-DsaValue $found[0] 'fields') 'Estado')
    if ($estado -ceq 'Nuevo') { return [pscustomobject]@{ Action = 'Trigger'; Estado = $estado; Reason = 'sigue en Nuevo' } }
    return [pscustomobject]@{ Action = 'Skip'; Estado = $estado; Reason = "está en '$estado'; el flujo ya lo tomó" }
}

# La URL del flujo viene de DSA_FLOW_URL: tiene que ser https y absoluta.
function Test-DsaFlowUrl {
    param([AllowNull()][AllowEmptyString()][string] $FlowUrl)
    if ([string]::IsNullOrWhiteSpace($FlowUrl)) { return $false }
    $uri = $null
    # Sin firma SAS (sig=): DisparoAgente se protege con Entra ID, no con un secreto en la URL (ADR-003, ADR-007).
    return [uri]::TryCreate($FlowUrl, [UriKind]::Absolute, [ref]$uri) -and $uri.Scheme -eq 'https' -and
        $uri.Query -notmatch '(?i)[?&]sig='
}

# Parámetros de Invoke-WebRequest para llamar a DisparoAgente con el cuerpo de §4.5: solo el eventId.
function New-DsaFlowRequest {
    param(
        [Parameter(Mandatory)][string] $FlowUrl,
        [Parameter(Mandatory)][string] $EventId,
        [Parameter(Mandatory)][string] $AccessToken
    )
    if (-not (Test-DsaFlowUrl $FlowUrl)) { throw 'DSA_FLOW_URL debe ser una URL https absoluta.' }
    if (-not (Test-DsaEventId $EventId)) { throw "EventId no válido: '$EventId'" }
    return @{
        Method      = 'Post'
        Uri         = $FlowUrl
        Headers     = @{ Authorization = "Bearer $AccessToken" }
        ContentType = 'application/json'
        Body        = (@{ eventId = $EventId } | ConvertTo-Json -Compress)
    }
}

# Para mostrar en pantalla sin exponer la ruta ni la consulta de la URL del flujo.
function Get-DsaSafeHost {
    param([AllowNull()][AllowEmptyString()][string] $Url)
    $uri = $null
    if ([uri]::TryCreate([string]$Url, [UriKind]::Absolute, [ref]$uri)) { return $uri.Host }
    return '(URL no válida)'
}

Export-ModuleMember -Function @(
    'ConvertTo-DsaBoolean', 'Select-DsaResetItems', 'Get-DsaResetTables', 'ConvertTo-DsaODataKey',
    'Get-DsaTableEntityUri', 'ConvertFrom-DsaEntityQuery', 'Get-DsaEntityQueryArguments',
    'Get-DsaTableDeleteHeaders', 'Format-DsaElapsed', 'Test-DsaEventId', 'Get-DsaItemByEventIdUri',
    'Get-DsaRetriggerDecision', 'Test-DsaFlowUrl', 'New-DsaFlowRequest', 'Get-DsaSafeHost'
)
