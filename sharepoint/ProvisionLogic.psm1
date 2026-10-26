#Requires -Version 7.0
<#
    T-029 (HU-07 CA-07.1, CA-07.2): lógica pura de sharepoint/provision.ps1.
    Sin Graph, sin red y sin escritura: el script obtiene el estado del tenant y este módulo solo
    compara, arma cuerpos de columnas y decide qué subir. Lo reutilizan demo/reset.ps1 y
    demo/retrigger.ps1 para leer .env, resolver el sitio y recorrer páginas de Graph.

    Referencias:
    - columnDefinition: https://learn.microsoft.com/graph/api/resources/columndefinition
    - Crear columna en una lista: https://learn.microsoft.com/graph/api/list-post-columns
    - Obtener un sitio por ruta: https://learn.microsoft.com/graph/api/site-getbypath
    - Paginación: https://learn.microsoft.com/graph/paging
#>

Set-StrictMode -Version 3.0

# Tipos de columnDefinition que admite el contrato (nombre de la faceta de Graph).
$script:SupportedTypes = @('text', 'choice', 'number', 'dateTime', 'boolean', 'personOrGroup')

# Facetas de tipo que puede traer una columna existente (son mutuamente excluyentes según Learn).
$script:TypeFacets = @(
    'boolean', 'calculated', 'choice', 'currency', 'dateTime', 'geolocation', 'hyperlinkOrPicture',
    'lookup', 'number', 'personOrGroup', 'term', 'text', 'thumbnail', 'contentApprovalStatus'
)

# Plantillas de lista que no cuentan al comprobar que DSA-Control está vacío: la biblioteca de
# páginas trae Home.aspx al crear el sitio.
$script:IgnoredTemplatesForEmptiness = @('webPageLibrary')

# --- Utilidades ---------------------------------------------------------------------------------

# Lee una propiedad de un hashtable (salida de Invoke-MgGraphRequest) o de un PSCustomObject.
function Get-DsaValue {
    param([AllowNull()][object] $Object, [Parameter(Mandatory)][string] $Name)
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        return $null
    }
    $property = $Object.PSObject.Properties[$Name]
    if ($property) { return $property.Value }
    return $null
}

# Convierte las líneas de un archivo .env en un hashtable. Ignora comentarios y líneas vacías.
function ConvertFrom-DsaDotEnv {
    param([AllowNull()][AllowEmptyCollection()][string[]] $Lines)
    $result = @{}
    foreach ($raw in @($Lines)) {
        if ($null -eq $raw) { continue }
        $line = $raw.Trim()
        if ($line -eq '' -or $line.StartsWith('#')) { continue }
        $index = $line.IndexOf('=')
        if ($index -lt 1) { continue }
        $key = $line.Substring(0, $index).Trim()
        $value = $line.Substring($index + 1).Trim()
        if ($value.Length -ge 2 -and (
                ($value.StartsWith('"') -and $value.EndsWith('"')) -or
                ($value.StartsWith("'") -and $value.EndsWith("'")))) {
            $value = $value.Substring(1, $value.Length - 2)
        }
        $result[$key] = $value
    }
    return $result
}

# Prioridad: parámetro explícito > variable de entorno del proceso > .env > valor por defecto.
function Resolve-DsaSetting {
    param(
        [AllowNull()][AllowEmptyString()][string] $Explicit,
        [Parameter(Mandatory)][string] $Name,
        [AllowNull()][hashtable] $DotEnv,
        [AllowNull()][hashtable] $ProcessEnv,
        [AllowNull()][AllowEmptyString()][string] $Default
    )
    if (-not [string]::IsNullOrWhiteSpace($Explicit)) { return $Explicit }
    if ($ProcessEnv -and -not [string]::IsNullOrWhiteSpace([string]$ProcessEnv[$Name])) { return [string]$ProcessEnv[$Name] }
    if ($DotEnv -and -not [string]::IsNullOrWhiteSpace([string]$DotEnv[$Name])) { return [string]$DotEnv[$Name] }
    if (-not [string]::IsNullOrWhiteSpace($Default)) { return $Default }
    return $null
}

# 'https://contoso.sharepoint.com/sites/x' -> 'contoso.sharepoint.com:/sites/x' (GET /sites/{host}:/{ruta}).
function ConvertTo-DsaSitePath {
    param([Parameter(Mandatory)][string] $SiteUrl)
    $uri = $null
    if (-not [uri]::TryCreate($SiteUrl.Trim(), [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -ne 'https') {
        throw "La URL del sitio debe ser absoluta y https: '$SiteUrl'"
    }
    $path = [uri]::UnescapeDataString($uri.AbsolutePath).TrimEnd('/')
    if ($path -eq '') { return $uri.Host }
    return "$($uri.Host):$path"
}

# URL del sitio de control a partir de la del sitio de la demo (mismo host, /sites/{Name}).
function Get-DsaControlSiteUrl {
    param([Parameter(Mandatory)][string] $SiteUrl, [string] $Name = 'DSA-Control')
    $null = ConvertTo-DsaSitePath -SiteUrl $SiteUrl
    $uri = [uri]$SiteUrl.Trim()
    return "https://$($uri.Host)/sites/$Name"
}

# Ámbitos que faltan en la sesión actual (comparación sin distinguir mayúsculas).
function Get-DsaMissingScopes {
    param(
        [AllowNull()][AllowEmptyCollection()][string[]] $Granted,
        [Parameter(Mandatory)][string[]] $Required
    )
    $have = @($Granted | Where-Object { $_ } | ForEach-Object { $_.ToLowerInvariant() })
    return @($Required | Where-Object { $have -notcontains $_.ToLowerInvariant() })
}

# Recorre todas las páginas de una consulta de Graph. $Invoker recibe la URI y devuelve la respuesta;
# así la función se prueba sin red.
function Invoke-DsaGraphPaged {
    param(
        [Parameter(Mandatory)][string] $Uri,
        [Parameter(Mandatory)][scriptblock] $Invoker,
        [int] $MaxPages = 100
    )
    $items = [System.Collections.Generic.List[object]]::new()
    $next = $Uri
    $pages = 0
    while ($next) {
        $pages++
        if ($pages -gt $MaxPages) { throw "Se superó el máximo de $MaxPages páginas en $Uri" }
        $response = & $Invoker $next
        foreach ($item in @(Get-DsaValue $response 'value')) {
            if ($null -ne $item) { $items.Add($item) }
        }
        $next = Get-DsaValue $response '@odata.nextLink'
    }
    return , $items.ToArray()
}

# Busca una lista por su nombre visible (sin distinguir mayúsculas). Devuelve $null si no existe.
function Find-DsaListByDisplayName {
    param(
        [AllowNull()][AllowEmptyCollection()][object[]] $Lists,
        [Parameter(Mandatory)][string] $DisplayName
    )
    foreach ($list in @($Lists)) {
        if ([string](Get-DsaValue $list 'displayName') -ieq $DisplayName) { return $list }
    }
    return $null
}

# --- Contrato de columnas -----------------------------------------------------------------------

# Valida el contrato (objeto de ConvertFrom-Json de columnas.json) y devuelve sus columnas.
function Assert-DsaColumnContract {
    param([Parameter(Mandatory)][object] $Contract)
    $columns = @(Get-DsaValue $Contract 'columns')
    if ($columns.Count -eq 0) { throw 'El contrato no tiene columnas.' }
    $names = @{}
    foreach ($column in $columns) {
        $name = [string](Get-DsaValue $column 'name')
        $type = [string](Get-DsaValue $column 'type')
        if ([string]::IsNullOrWhiteSpace($name)) { throw 'Hay una columna sin nombre en el contrato.' }
        if ($names.ContainsKey($name)) { throw "Columna repetida en el contrato: $name" }
        $names[$name] = $true
        if ($script:SupportedTypes -notcontains $type) { throw "Tipo no admitido en ${name}: '$type'" }
        if ($type -eq 'choice' -and @(Get-DsaValue $column 'choices').Count -eq 0) {
            throw "La columna de elección $name no tiene valores."
        }
        if ((Get-DsaValue $column 'unique') -and -not (Get-DsaValue $column 'indexed')) {
            throw "La columna $name es única pero no indexada; Graph exige índice para enforceUniqueValues."
        }
    }
    return , $columns
}

# Cuerpo de POST /sites/{site}/lists/{list}/columns para una columna del contrato.
function New-DsaColumnBody {
    param([Parameter(Mandatory)][object] $Column)
    $name = [string](Get-DsaValue $Column 'name')
    $displayName = [string](Get-DsaValue $Column 'displayName')
    if ([string]::IsNullOrWhiteSpace($displayName)) { $displayName = $name }
    $body = [ordered]@{
        name        = $name
        displayName = $displayName
        required    = [bool](Get-DsaValue $Column 'required')
    }
    if (Get-DsaValue $Column 'unique') {
        # enforceUniqueValues exige que la columna esté indexada.
        $body.enforceUniqueValues = $true
        $body.indexed = $true
    }
    elseif (Get-DsaValue $Column 'indexed') {
        $body.indexed = $true
    }
    switch ([string](Get-DsaValue $Column 'type')) {
        'text' {
            if (Get-DsaValue $Column 'multiline') {
                $body.text = [ordered]@{ allowMultipleLines = $true; textType = 'plain'; linesForEditing = 6 }
            }
            else {
                $body.text = [ordered]@{ allowMultipleLines = $false; maxLength = 255 }
            }
        }
        'choice' {
            $body.choice = [ordered]@{
                allowTextEntry = $false
                choices        = @(Get-DsaValue $Column 'choices' | ForEach-Object { [string]$_ })
                displayAs      = 'dropDownMenu'
            }
        }
        'number' {
            $number = [ordered]@{ decimalPlaces = if (Get-DsaValue $Column 'integer') { 'none' } else { 'automatic' } }
            $minimum = Get-DsaValue $Column 'minimum'
            if ($null -ne $minimum) { $number.minimum = [double]$minimum }
            $maximum = Get-DsaValue $Column 'maximum'
            if ($null -ne $maximum) { $number.maximum = [double]$maximum }
            $body.number = $number
        }
        'dateTime' { $body.dateTime = [ordered]@{ displayAs = 'standard'; format = 'dateTime' } }
        'boolean' { $body.boolean = [ordered]@{} }
        'personOrGroup' {
            $body.personOrGroup = [ordered]@{ allowMultipleSelection = $false; chooseFromType = 'peopleOnly' }
        }
        default { throw "Tipo no admitido: $(Get-DsaValue $Column 'type')" }
    }
    $default = Get-DsaValue $Column 'default'
    if ($null -ne $default) { $body.defaultValue = [ordered]@{ value = [string]$default } }
    return $body
}

# Nombre de la faceta de tipo de una columna que devuelve Graph ($null si no trae ninguna conocida).
function Get-DsaColumnType {
    param([Parameter(Mandatory)][object] $Column)
    foreach ($facet in $script:TypeFacets) {
        if ($null -ne (Get-DsaValue $Column $facet)) { return $facet }
    }
    return $null
}

<#
    Compara las columnas del contrato con las de la lista y devuelve una acción por columna:
    - Create   : no existe; Body es el cuerpo del POST.
    - Update   : existe con el mismo tipo pero le falta algo; Patch es el cuerpo del PATCH y Id su id.
    - Ok       : ya cumple el contrato.
    - Conflict : no se puede corregir sin riesgo (otro tipo, o el nombre visible lo usa otra columna).
    Las columnas de la lista que no están en el contrato no se tocan.
#>
function Compare-DsaColumns {
    param(
        [Parameter(Mandatory)][object[]] $Contract,
        [AllowNull()][AllowEmptyCollection()][object[]] $Existing
    )
    $existingList = @($Existing | Where-Object { $null -ne $_ })
    $results = [System.Collections.Generic.List[object]]::new()

    foreach ($wanted in $Contract) {
        $name = [string](Get-DsaValue $wanted 'name')
        $type = [string](Get-DsaValue $wanted 'type')
        $displayName = [string](Get-DsaValue $wanted 'displayName')
        if ([string]::IsNullOrWhiteSpace($displayName)) { $displayName = $name }
        $builtIn = [bool](Get-DsaValue $wanted 'builtIn')

        $current = $existingList | Where-Object { [string](Get-DsaValue $_ 'name') -ceq $name } | Select-Object -First 1
        if ($null -eq $current) {
            if ($builtIn) {
                $results.Add([pscustomobject]@{ Name = $name; Action = 'Conflict'; Id = $null; Body = $null; Patch = $null; Detail = 'columna integrada ausente' })
                continue
            }
            $clash = $existingList | Where-Object { [string](Get-DsaValue $_ 'displayName') -ieq $displayName } | Select-Object -First 1
            if ($clash) {
                $detail = "el nombre visible '$displayName' ya lo usa la columna '$(Get-DsaValue $clash 'name')'"
                $results.Add([pscustomobject]@{ Name = $name; Action = 'Conflict'; Id = $null; Body = $null; Patch = $null; Detail = $detail })
                continue
            }
            $results.Add([pscustomobject]@{ Name = $name; Action = 'Create'; Id = $null; Body = (New-DsaColumnBody -Column $wanted); Patch = $null; Detail = $type })
            continue
        }

        $id = Get-DsaValue $current 'id'
        $currentType = Get-DsaColumnType -Column $current
        if ($currentType -ne $type) {
            $results.Add([pscustomobject]@{ Name = $name; Action = 'Conflict'; Id = $id; Body = $null; Patch = $null; Detail = "tipo '$currentType', se esperaba '$type'" })
            continue
        }

        $patch = [ordered]@{}
        $changes = [System.Collections.Generic.List[string]]::new()

        if ($type -eq 'text') {
            $wantMulti = [bool](Get-DsaValue $wanted 'multiline')
            $haveMulti = [bool](Get-DsaValue (Get-DsaValue $current 'text') 'allowMultipleLines')
            if ($wantMulti -ne $haveMulti) {
                $detail = if ($wantMulti) { 'es de una línea y el contrato pide varias' } else { 'es de varias líneas y el contrato pide una' }
                $results.Add([pscustomobject]@{ Name = $name; Action = 'Conflict'; Id = $id; Body = $null; Patch = $null; Detail = $detail })
                continue
            }
        }

        if ([bool](Get-DsaValue $current 'required') -ne [bool](Get-DsaValue $wanted 'required')) {
            $patch.required = [bool](Get-DsaValue $wanted 'required')
            $changes.Add('required')
        }
        if (Get-DsaValue $wanted 'unique') {
            if (-not [bool](Get-DsaValue $current 'indexed')) { $patch.indexed = $true; $changes.Add('indexed') }
            if (-not [bool](Get-DsaValue $current 'enforceUniqueValues')) { $patch.enforceUniqueValues = $true; $changes.Add('enforceUniqueValues') }
        }
        elseif ((Get-DsaValue $wanted 'indexed') -and -not [bool](Get-DsaValue $current 'indexed')) {
            $patch.indexed = $true
            $changes.Add('indexed')
        }
        if (-not $builtIn -and [string](Get-DsaValue $current 'displayName') -cne $displayName) {
            $patch.displayName = $displayName
            $changes.Add('displayName')
        }
        if ($type -eq 'choice') {
            $haveChoices = @(Get-DsaValue (Get-DsaValue $current 'choice') 'choices' | ForEach-Object { [string]$_ })
            $missing = @(Get-DsaValue $wanted 'choices' | ForEach-Object { [string]$_ } | Where-Object { $haveChoices -cnotcontains $_ })
            if ($missing.Count -gt 0) {
                # Se agregan los valores que faltan sin quitar los que ya existen (no se pierden datos).
                $patch.choice = [ordered]@{
                    allowTextEntry = $false
                    choices        = @($haveChoices + $missing)
                    displayAs      = 'dropDownMenu'
                }
                $changes.Add("choices(+$($missing -join ', '))")
            }
        }
        $wantedDefault = Get-DsaValue $wanted 'default'
        if ($null -ne $wantedDefault) {
            $haveDefault = Get-DsaValue (Get-DsaValue $current 'defaultValue') 'value'
            if ([string]$haveDefault -cne [string]$wantedDefault) {
                $patch.defaultValue = [ordered]@{ value = [string]$wantedDefault }
                $changes.Add('defaultValue')
            }
        }

        if ($changes.Count -gt 0) {
            $results.Add([pscustomobject]@{ Name = $name; Action = 'Update'; Id = $id; Body = $null; Patch = $patch; Detail = ($changes -join ', ') })
        }
        else {
            $results.Add([pscustomobject]@{ Name = $name; Action = 'Ok'; Id = $id; Body = $null; Patch = $null; Detail = $type })
        }
    }
    # Se emite elemento a elemento para poder filtrar con la tubería.
    return $results.ToArray()
}

# Columnas de la biblioteca Protocolos (plan §4.4) más HashFuente, que guarda el hash de la fuente
# para no volver a subir un documento que no cambió (CA-07.2).
function Get-DsaLibraryColumnContract {
    param([Parameter(Mandatory)][object[]] $ListContract)
    $tipo = $ListContract | Where-Object { (Get-DsaValue $_ 'name') -ceq 'TipoEvento' } | Select-Object -First 1
    if (-not $tipo) { throw 'El contrato de la lista no tiene la columna TipoEvento.' }
    return @(
        [pscustomobject]@{ name = 'TipoEvento'; displayName = 'Tipo de evento'; type = 'choice'; required = $false; choices = @(Get-DsaValue $tipo 'choices') }
        # 'Versión del protocolo' evita chocar con el nombre visible 'Version' de la columna integrada _UIVersionString.
        [pscustomobject]@{ name = 'Version'; displayName = 'Versión del protocolo'; type = 'text'; required = $false }
        [pscustomobject]@{ name = 'HashFuente'; displayName = 'Hash de la fuente (SHA-256)'; type = 'text'; required = $false }
    )
}

# --- Protocolos ---------------------------------------------------------------------------------

# Metadatos de un protocolo: el tipo de evento es el nombre del archivo y la versión sale de la
# línea '**Versión:** x.y' del Markdown.
function Get-DsaProtocolMetadata {
    param(
        [Parameter(Mandatory)][string] $FileStem,
        [Parameter(Mandatory)][AllowEmptyString()][string] $Markdown,
        [Parameter(Mandatory)][string[]] $AllowedTypes
    )
    if ($AllowedTypes -cnotcontains $FileStem) {
        throw "El protocolo '$FileStem' no corresponde a ningún TipoEvento del contrato."
    }
    $match = [regex]::Match($Markdown, '\*\*Versi[oó]n:\*\*\s*([0-9]+(?:\.[0-9]+)*)')
    if (-not $match.Success) { throw "El protocolo '$FileStem' no tiene la línea '**Versión:** x.y'." }
    return [pscustomobject]@{ TipoEvento = $FileStem; Version = $match.Groups[1].Value; FileName = "$FileStem.docx" }
}

<#
    Hash SHA-256 (hex en minúsculas) de la fuente de un protocolo: el Markdown más el conversor.
    Se usa la fuente y no el .docx porque python-docx escribe fechas en el paquete y dos
    conversiones del mismo Markdown dan bytes distintos; con el hash del .docx cada ejecución
    volvería a subir los tres documentos y la segunda ejecución no quedaría sin cambios (CA-07.2).
    Si cambia el conversor, cambia el hash y se vuelven a subir todos, que es lo correcto.
#>
function Get-DsaProtocolHash {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][byte[]] $MarkdownBytes,
        [Parameter(Mandatory)][AllowEmptyCollection()][byte[]] $BuilderBytes
    )
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $mdHash = [Convert]::ToHexString($sha.ComputeHash($MarkdownBytes))
        $builderHash = [Convert]::ToHexString($sha.ComputeHash($BuilderBytes))
        $combined = [Text.Encoding]::ASCII.GetBytes("md:$mdHash;builder:$builderHash")
        return [Convert]::ToHexString($sha.ComputeHash($combined)).ToLowerInvariant()
    }
    finally { $sha.Dispose() }
}

<#
    Decide qué hacer con cada protocolo. $Local: FileName, Hash, TipoEvento, Version.
    $Remote: FileName, Hash (columna HashFuente), ListItemId. Acciones:
    - Upload  : no existe en la biblioteca.
    - Replace : existe con otro hash (o sin hash: una carga anterior quedó a medias).
    - Skip    : mismo hash.
    - Extra   : está en la biblioteca y no en protocols/; no se borra, solo se informa.
#>
function Get-DsaProtocolPlan {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]] $Local,
        [AllowNull()][AllowEmptyCollection()][object[]] $Remote
    )
    $remoteList = @($Remote | Where-Object { $null -ne $_ })
    $plan = [System.Collections.Generic.List[object]]::new()
    foreach ($doc in $Local) {
        $match = $remoteList | Where-Object { [string](Get-DsaValue $_ 'FileName') -ieq [string]$doc.FileName } | Select-Object -First 1
        if (-not $match) {
            $plan.Add([pscustomobject]@{ FileName = $doc.FileName; Action = 'Upload'; Local = $doc; ListItemId = $null })
        }
        elseif ([string](Get-DsaValue $match 'Hash') -ine [string]$doc.Hash) {
            $plan.Add([pscustomobject]@{ FileName = $doc.FileName; Action = 'Replace'; Local = $doc; ListItemId = (Get-DsaValue $match 'ListItemId') })
        }
        else {
            $plan.Add([pscustomobject]@{ FileName = $doc.FileName; Action = 'Skip'; Local = $doc; ListItemId = (Get-DsaValue $match 'ListItemId') })
        }
    }
    foreach ($item in $remoteList) {
        $fileName = [string](Get-DsaValue $item 'FileName')
        if (-not ($Local | Where-Object { [string]$_.FileName -ieq $fileName })) {
            $plan.Add([pscustomobject]@{ FileName = $fileName; Action = 'Extra'; Local = $null; ListItemId = (Get-DsaValue $item 'ListItemId') })
        }
    }
    return $plan.ToArray()
}

# Convierte los elementos de la biblioteca (items?expand=fields) en FileName, Hash y ListItemId.
function ConvertFrom-DsaLibraryItems {
    param([AllowNull()][AllowEmptyCollection()][object[]] $Items)
    $result = foreach ($item in @($Items | Where-Object { $null -ne $_ })) {
        $fields = Get-DsaValue $item 'fields'
        $fileName = [string](Get-DsaValue $fields 'FileLeafRef')
        if ([string]::IsNullOrWhiteSpace($fileName)) { continue }
        [pscustomobject]@{ FileName = $fileName; Hash = [string](Get-DsaValue $fields 'HashFuente'); ListItemId = [string](Get-DsaValue $item 'id') }
    }
    return , @($result)
}

# --- Sitio de control ---------------------------------------------------------------------------

<#
    DSA-Control debe estar vacío (CA-06.2, CA-07.1). $Lists: displayName, template, hidden, itemCount.
    No cuentan las listas ocultas ni la biblioteca de páginas (trae Home.aspx al crear el sitio).
#>
function Test-DsaControlSiteEmpty {
    param([AllowNull()][AllowEmptyCollection()][object[]] $Lists)
    $nonEmpty = @(
        $Lists | Where-Object { $null -ne $_ } | Where-Object {
            -not [bool](Get-DsaValue $_ 'hidden') -and
            $script:IgnoredTemplatesForEmptiness -notcontains [string](Get-DsaValue $_ 'template') -and
            [int](Get-DsaValue $_ 'itemCount') -gt 0
        } | ForEach-Object { [string](Get-DsaValue $_ 'displayName') }
    )
    return [pscustomobject]@{ IsEmpty = ($nonEmpty.Count -eq 0); NonEmpty = $nonEmpty }
}

# --- Errores HTTP -------------------------------------------------------------------------------

# Código HTTP de un error de Invoke-MgGraphRequest o Invoke-WebRequest ($null si no se puede leer).
function Get-DsaHttpStatus {
    param([AllowNull()][object] $ErrorRecord)
    if ($null -eq $ErrorRecord) { return $null }
    $exception = if ($ErrorRecord -is [System.Management.Automation.ErrorRecord]) { $ErrorRecord.Exception } else { $ErrorRecord }
    $response = Get-DsaValue $exception 'Response'
    $code = Get-DsaValue $response 'StatusCode'
    if ($null -ne $code) { return [int]$code }
    $message = [string](Get-DsaValue $exception 'Message')
    if ($message -match '\b(NotFound|404)\b') { return 404 }
    if ($message -match '\b(Forbidden|403)\b') { return 403 }
    if ($message -match '\b(Unauthorized|401)\b') { return 401 }
    return $null
}

# --- Salida -------------------------------------------------------------------------------------

# Línea de salida legible con su color. Estados: Created, Exists, Updated, WhatIf, Warning, Error, Info.
function Format-DsaLine {
    param(
        [Parameter(Mandatory)][ValidateSet('Created', 'Exists', 'Updated', 'WhatIf', 'Warning', 'Error', 'Info')][string] $Status,
        [Parameter(Mandatory)][string] $Message
    )
    $map = @{
        Created = @('[creado]      ', 'Green')
        Exists  = @('[ya existía]  ', 'Gray')
        Updated = @('[completado]  ', 'Cyan')
        WhatIf  = @('[se haría]    ', 'Yellow')
        Warning = @('[aviso]       ', 'Yellow')
        Error   = @('[error]       ', 'Red')
        Info    = @('              ', 'White')
    }
    return [pscustomobject]@{ Text = "$($map[$Status][0])$Message"; Color = $map[$Status][1]; Status = $Status }
}

Export-ModuleMember -Function @(
    'Get-DsaValue', 'ConvertFrom-DsaDotEnv', 'Resolve-DsaSetting', 'ConvertTo-DsaSitePath',
    'Get-DsaControlSiteUrl', 'Get-DsaMissingScopes', 'Invoke-DsaGraphPaged', 'Find-DsaListByDisplayName',
    'Assert-DsaColumnContract', 'New-DsaColumnBody', 'Get-DsaColumnType', 'Compare-DsaColumns',
    'Get-DsaLibraryColumnContract', 'Get-DsaProtocolMetadata', 'Get-DsaProtocolHash', 'Get-DsaProtocolPlan',
    'ConvertFrom-DsaLibraryItems', 'Test-DsaControlSiteEmpty', 'Get-DsaHttpStatus', 'Format-DsaLine'
)
