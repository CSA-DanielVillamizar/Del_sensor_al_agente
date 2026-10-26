#Requires -Version 7.0
<#
    T-040 (HU-08 CA-08.6, HU-05 CA-05.5): lógica pura de demo/measure.ps1 y demo/inject.ps1.
    Sin Graph, sin red y sin reloj real: los scripts obtienen los datos y este módulo solo calcula.
    Los percentiles vienen de spikes/p1-latencia/SpikeLogic.psm1 (ya probado con Pester).
#>

Import-Module (Join-Path $PSScriptRoot '..' 'spikes' 'p1-latencia' 'SpikeLogic.psm1') -Force

# Escala única de §5.0, de menor a mayor.
$script:Scale = @('Baja', 'Media', 'Alta', 'Crítica')
$script:EventTypes = @('movimiento_zona_restringida', 'puerta_forzada', 'acceso_denegado_repetido')

# Columnas que escribe la Function según el plan §4.3; se usan solo si aún no existe sharepoint/columnas.json.
$script:PlanFunctionColumns = @(
    'Title', 'EventId', 'DeviceId', 'TipoEvento', 'Zona', 'NombreZona', 'CamaraId', 'Sitio',
    'SeveridadRaw', 'SeveridadInicial', 'Repeticiones', 'FechaEventoUtc', 'RecibidoUtc', 'EsPrueba', 'Estado'
)

$script:FlowAudience = 'https://service.flow.microsoft.com/'
$script:RefPattern = 'Ref\.\s*([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})'

# --- Fechas ---------------------------------------------------------------------------------------

# Normaliza texto ISO 8601, DateTime o DateTimeOffset a DateTime UTC. Un DateTime sin zona se toma como UTC.
function ConvertTo-UtcDateTime {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value -or ($Value -is [string] -and [string]::IsNullOrWhiteSpace($Value))) { return $null }
    if ($Value -is [DateTimeOffset]) { return $Value.UtcDateTime }
    if ($Value -is [datetime]) {
        switch ($Value.Kind) {
            'Utc' { return $Value }
            'Local' { return $Value.ToUniversalTime() }
            default { return [datetime]::SpecifyKind($Value, [DateTimeKind]::Utc) }
        }
    }
    $styles = [Globalization.DateTimeStyles]::AssumeUniversal
    return [DateTimeOffset]::Parse([string]$Value, [cultureinfo]::InvariantCulture, $styles).UtcDateTime
}

function Format-UtcIso {
    param([Parameter(Mandatory)][datetime]$Utc)
    return (ConvertTo-UtcDateTime $Utc).ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [cultureinfo]::InvariantCulture)
}

# America/Bogota es UTC−05:00 todo el año (Colombia no usa horario de verano).
function ConvertTo-BogotaTime {
    param([Parameter(Mandatory)][datetime]$Utc)
    return [datetime]::SpecifyKind((ConvertTo-UtcDateTime $Utc).AddHours(-5), [DateTimeKind]::Unspecified)
}

# Horario diurno de la regla de §5.0: 06:00 ≤ hora < 18:00 en America/Bogota.
function Test-Daytime {
    param([Parameter(Mandatory)][datetime]$Utc)
    $t = (ConvertTo-BogotaTime -Utc $Utc).TimeOfDay
    return ($t -ge [timespan]'06:00:00' -and $t -lt [timespan]'18:00:00')
}

# --- Severidad y catálogo --------------------------------------------------------------------------

function Get-SeverityRank {
    param([Parameter(Mandatory)][string]$Severity)
    $rank = [array]::IndexOf($script:Scale, $Severity)
    if ($rank -lt 0) { throw "Severidad '$Severity' fuera de la escala de §5.0 ($($script:Scale -join ', '))." }
    return $rank
}

# SeveridadInicial = el mayor entre rawSeverity del evento y baseSeverity de la zona (§5.0).
function Get-SeveridadInicial {
    param([Parameter(Mandatory)][string]$RawSeverity, [Parameter(Mandatory)][string]$BaseSeverity)
    $rank = [math]::Max((Get-SeverityRank $RawSeverity), (Get-SeverityRank $BaseSeverity))
    return $script:Scale[$rank]
}

function Get-ZoneEntry {
    param([Parameter(Mandatory)][object[]]$Zones, [Parameter(Mandatory)][string]$Zone)
    $entry = $Zones | Where-Object { $_.zone -eq $Zone } | Select-Object -First 1
    if (-not $entry) { throw "La zona '$Zone' no está en el catálogo data/zonas.json." }
    return $entry
}

# --- Contrato de columnas e incidente ----------------------------------------------------------

function Get-FunctionColumnNames {
    param([Parameter(Mandatory)][string]$ContractPath)
    if (-not (Test-Path -LiteralPath $ContractPath)) { return , $script:PlanFunctionColumns.Clone() }
    $contract = Get-Content -LiteralPath $ContractPath -Raw -Encoding utf8 | ConvertFrom-Json
    $names = @($contract.columns | Where-Object { $_.writers -contains 'function' } | ForEach-Object { $_.name })
    return , $names
}

# Arma los campos que escribiría la Function (plan §4.3) para un incidente nuevo.
function New-IncidentFields {
    param(
        [Parameter(Mandatory)][string]$EventId,
        [Parameter(Mandatory)][string]$DeviceId,
        [Parameter(Mandatory)][string]$Type,
        [Parameter(Mandatory)][string]$Zone,
        [Parameter(Mandatory)][string]$RawSeverity,
        [Parameter(Mandatory)][object[]]$Zones,
        [Parameter(Mandatory)][datetime]$FechaEventoUtc,
        [Parameter(Mandatory)][datetime]$RecibidoUtc,
        [ValidateRange(1, 1000000)][int]$Repeticiones = 1,
        [switch]$EsPrueba,
        [Parameter(Mandatory)][string[]]$ColumnNames
    )
    $guid = [guid]::Empty
    if (-not [guid]::TryParse($EventId, [ref]$guid)) { throw "EventId '$EventId' no es un UUID." }
    if ($script:EventTypes -notcontains $Type) {
        throw "El tipo de evento '$Type' no es válido. Tipos: $($script:EventTypes -join ', ')."
    }
    if ($DeviceId -cnotmatch '^DEV-[A-Z0-9-]+$') { throw "DeviceId '$DeviceId' no cumple el patrón ^DEV-[A-Z0-9-]+$." }
    if ($Zone -notmatch '^Z-\d{2}$') { throw "La zona '$Zone' no cumple el patrón ^Z-\d{2}$." }
    $fecha = ConvertTo-UtcDateTime $FechaEventoUtc
    $recibido = ConvertTo-UtcDateTime $RecibidoUtc
    if ($fecha -gt $recibido) { throw 'FechaEventoUtc es posterior a RecibidoUtc.' }

    $z = Get-ZoneEntry -Zones $Zones -Zone $Zone
    $values = @{
        Title            = "$Type · $Zone"
        EventId          = $guid.ToString()
        DeviceId         = $DeviceId
        TipoEvento       = $Type
        Zona             = $Zone
        NombreZona       = $z.zoneName
        CamaraId         = $z.cameraId
        Sitio            = $z.site
        SeveridadRaw     = $script:Scale[(Get-SeverityRank $RawSeverity)]
        SeveridadInicial = Get-SeveridadInicial -RawSeverity $RawSeverity -BaseSeverity $z.baseSeverity
        Repeticiones     = $Repeticiones
        FechaEventoUtc   = Format-UtcIso $fecha
        RecibidoUtc      = Format-UtcIso $recibido
        EsPrueba         = [bool]$EsPrueba
        Estado           = 'Nuevo'
    }
    $fields = [ordered]@{}
    foreach ($name in $ColumnNames) {
        if (-not $values.ContainsKey($name)) { throw "El contrato pide la columna '$name' y inject no sabe llenarla." }
        $fields[$name] = $values[$name]
    }
    return $fields
}

function ConvertTo-GraphItemBody {
    param([Parameter(Mandatory, ValueFromPipeline)][System.Collections.IDictionary]$Fields)
    process { return (@{ fields = $Fields } | ConvertTo-Json -Depth 5) }
}

# --- Llamada al flujo DisparoAgente ------------------------------------------------------------

function Test-FlowUrl {
    param([AllowEmptyString()][AllowNull()][string]$Url)
    $uri = $null
    if (-not [uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$uri)) { return $false }
    # Sin firma SAS (sig=): DisparoAgente se protege con Entra ID, no con un secreto en la URL (ADR-003, ADR-007).
    return ($uri.Scheme -eq 'https') -and ($uri.Query -notmatch '(?i)[?&]sig=')
}

# La URL del flujo no se muestra nunca completa (puede llevar parámetros sensibles).
function Get-RedactedUrl {
    param([Parameter(Mandatory)][string]$Url)
    $uri = [uri]$Url
    return "$($uri.Scheme)://$($uri.Host)/…"
}

function New-FlowRequest {
    param(
        [Parameter(Mandatory)][string]$FlowUrl,
        [Parameter(Mandatory)][string]$Token,
        [Parameter(Mandatory)][string]$EventId
    )
    return @{
        Uri         = $FlowUrl
        Method      = 'Post'
        Headers     = @{ Authorization = "Bearer $Token" }
        ContentType = 'application/json'
        Body        = (@{ eventId = $EventId } | ConvertTo-Json -Compress)
    }
}

# Lee la audiencia (aud) del JWT sin validarlo: solo sirve para fallar pronto con un mensaje claro.
function Get-TokenAudience {
    param([Parameter(Mandatory)][string]$Token)
    $parts = $Token.Split('.')
    if ($parts.Count -lt 2) { return $null }
    $payload = $parts[1].Replace('-', '+').Replace('_', '/')
    switch ($payload.Length % 4) { 2 { $payload += '==' } 3 { $payload += '=' } }
    try {
        $json = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload)) | ConvertFrom-Json
        return $json.aud
    }
    catch { return $null }
}

function Test-FlowTokenAudience {
    param([Parameter(Mandatory)][string]$Token)
    return ((Get-TokenAudience $Token) -eq $script:FlowAudience)
}

# --- Medición del tramo 2 y del total ------------------------------------------------------------

function Get-Prop {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) { return $Object[$Name] }
    return $Object.$Name
}

# Busca "Ref. {eventId}" en el cuerpo del mensaje y en las tarjetas adjuntas (el Flow bot publica la tarjeta
# como adjunto; el cuerpo solo lleva la etiqueta <attachment>).
function Find-EventReference {
    param([Parameter(Mandatory)]$Message)
    $texts = @([string](Get-Prop (Get-Prop $Message 'body') 'content'))
    foreach ($a in @(Get-Prop $Message 'attachments')) {
        if ($null -ne $a) { $texts += [string](Get-Prop $a 'content') }
    }
    foreach ($t in $texts) {
        $m = [regex]::Match($t, $script:RefPattern)
        if ($m.Success) { return $m.Groups[1].Value.ToLowerInvariant() }
    }
    return $null
}

function Select-LastItems {
    param([object[]]$Items, [Parameter(Mandatory)][int]$Last)
    return @($Items | Sort-Object CreatedUtc | Select-Object -Last $Last)
}

<#
    Une elementos y mensajes por eventId. Items: EventId, CreatedUtc (createdDateTime del elemento) y
    RecibidoUtc (enqueuedTimeUtc). La tarjeta visible es el primer mensaje con "Ref. {eventId}" (el aviso
    "Sin respuesta" llega después y no cuenta). Sin tarjeta pasado TimeoutSeconds = vencido (+Infinito).
#>
function Join-IncidentMessages {
    param(
        [object[]]$Items,
        [object[]]$Messages,
        [Parameter(Mandatory)][datetime]$Now,
        [int]$TimeoutSeconds = 60
    )
    $first = @{}
    foreach ($m in @($Messages)) {
        if ($null -eq $m) { continue }
        $id = Find-EventReference $m
        if (-not $id) { continue }
        $created = ConvertTo-UtcDateTime (Get-Prop $m 'createdDateTime')
        if (-not $first.ContainsKey($id) -or $created -lt $first[$id]) { $first[$id] = $created }
    }
    $nowUtc = ConvertTo-UtcDateTime $Now
    foreach ($item in @($Items)) {
        if ($null -eq $item) { continue }
        $id = ([string]$item.EventId).ToLowerInvariant()
        $created = ConvertTo-UtcDateTime $item.CreatedUtc
        $recibido = ConvertTo-UtcDateTime $item.RecibidoUtc
        $card = if ($first.ContainsKey($id)) { $first[$id] } else { $null }
        [pscustomobject]@{
            EventId     = $item.EventId
            RecibidoUtc = $recibido
            CreatedUtc  = $created
            CardUtc     = $card
            Tramo1      = if ($recibido) { ($created - $recibido).TotalSeconds } else { $null }
            Tramo2      = if ($card) { ($card - $created).TotalSeconds } else { $null }
            Total       = if ($card -and $recibido) { ($card - $recibido).TotalSeconds } else { $null }
            Vencido     = (-not $card) -and (($nowUtc - $created).TotalSeconds -gt $TimeoutSeconds)
        }
    }
}

function Get-Stats {
    param([double[]]$Values)
    if ($Values.Count -eq 0) { return @{ P50 = $null; P90 = $null; Max = $null } }
    return @{
        P50 = Get-Percentile -Values $Values -P 50
        P90 = Get-Percentile -Values $Values -P 90
        Max = [double]($Values | Measure-Object -Maximum).Maximum
    }
}

# RNF-01: tramo 2 p90 ≤ 20 s; total p90 ≤ 30 s y nunca > 60 s. Un incidente sin tarjeta nunca se excluye.
function Get-LatencySummary {
    param(
        [Parameter(Mandatory)][object[]]$Rows,
        [int]$Tramo2TargetSeconds = 20,
        [int]$TotalTargetSeconds = 30,
        [int]$TotalMaxSeconds = 60,
        [int]$MinSamples = 10
    )
    $inf = [double]::PositiveInfinity
    $lost = @($Rows | Where-Object { $_.Vencido }).Count
    $pending = @($Rows | Where-Object { $null -eq $_.Tramo2 -and -not $_.Vencido }).Count
    $t1 = @($Rows | Where-Object { $null -ne $_.Tramo1 } | ForEach-Object { [double]$_.Tramo1 })
    $t2 = @($Rows | Where-Object { $null -ne $_.Tramo2 -or $_.Vencido } |
            ForEach-Object { if ($_.Vencido) { $inf } else { [double]$_.Tramo2 } })
    $tt = @($Rows | Where-Object { $null -ne $_.Total -or $_.Vencido } |
            ForEach-Object { if ($_.Vencido) { $inf } else { [double]$_.Total } })
    $s1 = Get-Stats $t1; $s2 = Get-Stats $t2; $st = Get-Stats $tt

    if ($pending -gt 0) { $verdict = 'Pendiente' }
    elseif ($t2.Count -eq 0) { $verdict = 'Sin datos' }
    else {
        $ok = ($lost -eq 0) -and ($s2.P90 -le $Tramo2TargetSeconds)
        if ($tt.Count -gt 0) { $ok = $ok -and ($st.P90 -le $TotalTargetSeconds) -and ($st.Max -le $TotalMaxSeconds) }
        $verdict = if (-not $ok) { 'No cumple' } elseif ($Rows.Count -lt $MinSamples) { 'Cumple (muestra < 10)' } else { 'Cumple' }
    }
    return [pscustomobject]@{
        N          = $Rows.Count
        Pendientes = $pending
        SinTarjeta = $lost
        Tramo1P50  = $s1.P50; Tramo1P90 = $s1.P90; Tramo1Max = $s1.Max
        Tramo2P50  = $s2.P50; Tramo2P90 = $s2.P90; Tramo2Max = $s2.Max
        TotalP50   = $st.P50; TotalP90 = $st.P90; TotalMax = $st.Max
        Veredicto  = $verdict
    }
}

function ConvertTo-LatencyMarkdown {
    param([Parameter(Mandatory)]$Summary, [Parameter(Mandatory)][datetime]$GeneratedUtc)
    $lines = @(
        '# Medición de latencia (CA-08.6, RNF-01)',
        '',
        "Generado: $($GeneratedUtc.ToString('yyyy-MM-dd HH:mm')) UTC. Incidentes: $($Summary.N); sin tarjeta: $($Summary.SinTarjeta); pendientes: $($Summary.Pendientes).",
        '',
        '| Tramo | p50 | p90 | máx | Meta |',
        '| --- | --- | --- | --- | --- |',
        ('| Tramo 1 (aprox.) | {0} | {1} | {2} | p90 ≤ 10 s (la medición oficial es la KQL) |' -f (Format-Seconds $Summary.Tramo1P50), (Format-Seconds $Summary.Tramo1P90), (Format-Seconds $Summary.Tramo1Max)),
        ('| Tramo 2 | {0} | {1} | {2} | p90 ≤ 20 s |' -f (Format-Seconds $Summary.Tramo2P50), (Format-Seconds $Summary.Tramo2P90), (Format-Seconds $Summary.Tramo2Max)),
        ('| Total | {0} | {1} | {2} | p90 ≤ 30 s, máx ≤ 60 s |' -f (Format-Seconds $Summary.TotalP50), (Format-Seconds $Summary.TotalP90), (Format-Seconds $Summary.TotalMax)),
        '',
        "Veredicto: $($Summary.Veredicto)"
    )
    return $lines
}

Export-ModuleMember -Function ConvertTo-UtcDateTime, Format-UtcIso, ConvertTo-BogotaTime, Test-Daytime,
    Get-SeverityRank, Get-SeveridadInicial, Get-ZoneEntry, Get-FunctionColumnNames, New-IncidentFields,
    ConvertTo-GraphItemBody, Test-FlowUrl, Get-RedactedUrl, New-FlowRequest, Get-TokenAudience,
    Test-FlowTokenAudience, Find-EventReference, Select-LastItems, Join-IncidentMessages, Get-LatencySummary,
    ConvertTo-LatencyMarkdown
