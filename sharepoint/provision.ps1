#Requires -Version 7.0
<#
.SYNOPSIS
    T-029 (HU-07 CA-07.1, CA-07.2): crea o completa la lista 'Eventos de seguridad' y la biblioteca
    'Protocolos', comprueba que el sitio de control DSA-Control existe y está vacío, y sube los
    protocolos .docx que cambiaron.

.DESCRIPTION
    Idempotente: compara el tenant contra sharepoint/columnas.json y solo agrega lo que falta.
    Una segunda ejecución seguida no crea nada (CA-07.2).

    Identidad: sesión DELEGADA e interactiva de Daniel con el módulo Microsoft.Graph.Authentication.
    Ningún secreto, token ni credencial se guarda en archivos.

    Ámbitos de Graph (delegados) y por qué son los mínimos:
    - Sites.Manage.All: crear listas y bibliotecas y agregar o modificar columnas. Learn lo marca
      como el menor privilegio para POST /sites/{id}/lists y POST .../columns; Sites.ReadWrite.All no
      basta para crear listas en delegado. También permite leer el sitio y editar los metadatos de
      los documentos ("manage and create lists, documents, and list items").
      https://learn.microsoft.com/graph/api/list-create#permissions
      https://learn.microsoft.com/onedrive/developer/rest-api/concepts/permissions_reference#sites-permissions
    - Files.ReadWrite.All: subir o reemplazar el contenido de un .docx en la biblioteca de un sitio
      (PUT /drives/{id}/root:/{archivo}:/content). Files.ReadWrite solo cubre los archivos propios.
      https://learn.microsoft.com/graph/api/driveitem-put-content#permissions
    No se pide Sites.FullControl.All (no se cambian permisos) ni nada de aplicación.

    DSA-Control NO se crea: si falta, el script lo informa en rojo y sigue con el resto. Se crea a
    mano en el portal de SharePoint (CA-06.2).

    -WhatIf no escribe nada en el tenant ni genera .docx: lee el estado (necesita sesión de solo
    lectura con los mismos ámbitos) y muestra lo que haría. Si el módulo de Graph no está instalado,
    -WhatIf muestra solo la parte local (contrato y hashes) y termina sin error.
    -LocalOnly valida solo la parte local (contrato, metadatos y hashes de protocols/) sin abrir
    sesión; sirve para comprobar el script en CI o sin acceso al tenant.

.PARAMETER SiteUrl
    URL del sitio de la demo. Si se omite se toma de DSA_SITE_URL (variable de entorno o .env).

.PARAMETER ControlSiteUrl
    URL de DSA-Control. Por defecto, https://{mismo host}/sites/DSA-Control.

.PARAMETER EnvFile
    Ruta del .env (no versionado). Por defecto, el .env de la raíz del repositorio.

.EXAMPLE
    pwsh -File sharepoint/provision.ps1 -WhatIf
    pwsh -File sharepoint/provision.ps1 -SiteUrl https://contoso.sharepoint.com/sites/dsa-demo
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string] $SiteUrl,
    [string] $ControlSiteUrl,
    [string] $ListName,
    [string] $LibraryName = 'Protocolos',
    [string] $EnvFile,
    [switch] $SkipProtocols,
    [switch] $LocalOnly
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

# -WhatIf se controla a mano: así ningún cmdlet de lectura se salta por la preferencia heredada.
$dryRun = [bool]$WhatIfPreference
$WhatIfPreference = $false

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
Import-Module (Join-Path $PSScriptRoot 'ProvisionLogic.psm1') -Force

$RequiredScopes = @('Sites.Manage.All', 'Files.ReadWrite.All')
$DocxMime = 'application/vnd.openxmlformats-officedocument.wordprocessingml.document'

$script:Counts = @{ Created = 0; Exists = 0; Updated = 0; WhatIf = 0; Warning = 0; Error = 0; Info = 0 }

function Write-DsaLine {
    param([string] $Status, [string] $Message)
    $line = Format-DsaLine -Status $Status -Message $Message
    $script:Counts[$Status]++
    Write-Host $line.Text -ForegroundColor $line.Color
}

function Invoke-DsaGraph {
    param(
        [string] $Method = 'GET',
        [Parameter(Mandatory)][string] $Uri,
        [object] $Body,
        [string] $InputFilePath,
        [string] $ContentType
    )
    $params = @{ Method = $Method; Uri = $Uri; OutputType = 'HashTable' }
    if ($null -ne $Body) {
        # EscapeNonAscii: el cuerpo viaja en ASCII y las tildes no dependen de la codificación.
        $params.Body = $Body | ConvertTo-Json -Depth 10 -Compress -EscapeHandling EscapeNonAscii
        $params.ContentType = 'application/json'
    }
    if ($InputFilePath) {
        $params.InputFilePath = $InputFilePath
        $params.ContentType = $ContentType
    }
    return Invoke-MgGraphRequest @params
}

function Get-DsaPaged {
    param([Parameter(Mandatory)][string] $Uri)
    return Invoke-DsaGraphPaged -Uri $Uri -Invoker { param($u) Invoke-DsaGraph -Uri $u }
}

# Devuelve el sitio o $null si no existe (404).
function Get-DsaSite {
    param([Parameter(Mandatory)][string] $Url)
    $path = ConvertTo-DsaSitePath -SiteUrl $Url
    try {
        return Invoke-DsaGraph -Uri "v1.0/sites/$path`?`$select=id,displayName,webUrl"
    }
    catch {
        if ((Get-DsaHttpStatus $_) -eq 404) { return $null }
        throw
    }
}

# Crea la lista si falta y aplica el contrato de columnas. Devuelve el id de la lista ($null en -WhatIf si no existía).
function Initialize-DsaList {
    param(
        [Parameter(Mandatory)][string] $SiteId,
        [Parameter(Mandatory)][string] $DisplayName,
        [Parameter(Mandatory)][ValidateSet('genericList', 'documentLibrary')][string] $Template,
        [Parameter(Mandatory)][object[]] $Columns,
        [Parameter(Mandatory)][object[]] $SiteLists
    )
    $kind = if ($Template -eq 'genericList') { 'Lista' } else { 'Biblioteca' }
    $list = Find-DsaListByDisplayName -Lists $SiteLists -DisplayName $DisplayName
    $listId = $null
    if ($list) {
        $listId = [string](Get-DsaValue $list 'id')
        Write-DsaLine Exists "$kind '$DisplayName'"
    }
    elseif ($dryRun) {
        Write-DsaLine WhatIf "$kind '$DisplayName' (plantilla $Template)"
    }
    else {
        $created = Invoke-DsaGraph -Method POST -Uri "v1.0/sites/$SiteId/lists" -Body ([ordered]@{
                displayName = $DisplayName
                list        = [ordered]@{ template = $Template }
            })
        $listId = [string](Get-DsaValue $created 'id')
        Write-DsaLine Created "$kind '$DisplayName'"
    }

    $existing = @()
    if ($listId) { $existing = Get-DsaPaged -Uri "v1.0/sites/$SiteId/lists/$listId/columns" }

    foreach ($step in (Compare-DsaColumns -Contract $Columns -Existing $existing)) {
        $label = "  columna $($step.Name)"
        switch ($step.Action) {
            'Ok' { Write-DsaLine Exists $label }
            'Conflict' { Write-DsaLine Error "$label`: $($step.Detail). Corrígela en el portal; el script no la cambia." }
            'Create' {
                if ($dryRun) { Write-DsaLine WhatIf "$label ($($step.Detail))"; continue }
                $null = Invoke-DsaGraph -Method POST -Uri "v1.0/sites/$SiteId/lists/$listId/columns" -Body $step.Body
                Write-DsaLine Created "$label ($($step.Detail))"
            }
            'Update' {
                if ($dryRun) { Write-DsaLine WhatIf "$label`: $($step.Detail)"; continue }
                $null = Invoke-DsaGraph -Method PATCH -Uri "v1.0/sites/$SiteId/lists/$listId/columns/$($step.Id)" -Body $step.Patch
                Write-DsaLine Updated "$label`: $($step.Detail)"
            }
        }
    }
    return $listId
}

# --- 1. Configuración ---------------------------------------------------------------------------

Write-Host ''
Write-Host 'Aprovisionamiento de SharePoint — Del sensor al agente (T-029)' -ForegroundColor White
if ($dryRun) { Write-Host 'Modo -WhatIf: no se escribe nada en el tenant ni se generan .docx.' -ForegroundColor Yellow }

if (-not $EnvFile) { $EnvFile = Join-Path $repoRoot '.env' }
$dotEnv = if (Test-Path -LiteralPath $EnvFile) { ConvertFrom-DsaDotEnv -Lines (Get-Content -LiteralPath $EnvFile) } else { @{} }
$processEnv = @{}
foreach ($name in 'DSA_SITE_URL', 'DSA_LIST_NAME') { $processEnv[$name] = [Environment]::GetEnvironmentVariable($name) }

$contractPath = Join-Path $PSScriptRoot 'columnas.json'
$contract = Get-Content -LiteralPath $contractPath -Raw -Encoding utf8 | ConvertFrom-Json
$listColumns = Assert-DsaColumnContract -Contract $contract
$libraryColumns = Get-DsaLibraryColumnContract -ListContract $listColumns

$SiteUrl = Resolve-DsaSetting -Explicit $SiteUrl -Name 'DSA_SITE_URL' -DotEnv $dotEnv -ProcessEnv $processEnv
$ListName = Resolve-DsaSetting -Explicit $ListName -Name 'DSA_LIST_NAME' -DotEnv $dotEnv -ProcessEnv $processEnv -Default ([string]$contract.list)
if (-not $SiteUrl) {
    Write-DsaLine Error 'Falta la URL del sitio: usa -SiteUrl o define DSA_SITE_URL en .env.'
    exit 2
}
try {
    $null = ConvertTo-DsaSitePath -SiteUrl $SiteUrl
    if (-not $ControlSiteUrl) { $ControlSiteUrl = Get-DsaControlSiteUrl -SiteUrl $SiteUrl }
    $null = ConvertTo-DsaSitePath -SiteUrl $ControlSiteUrl
}
catch {
    Write-DsaLine Error $_.Exception.Message
    exit 2
}

Write-DsaLine Info "Sitio de la demo: $SiteUrl"
Write-DsaLine Info "Sitio de control: $ControlSiteUrl"
Write-DsaLine Info "Lista: '$ListName' ($($listColumns.Count) columnas en columnas.json v$($contract.version)); biblioteca: '$LibraryName'"

# --- 2. Protocolos locales (sin tenant) ---------------------------------------------------------

$builder = Join-Path $PSScriptRoot 'build-protocols.py'
$protocolDir = Join-Path $repoRoot 'protocols'
$distDir = Join-Path $protocolDir 'dist'
$allowedTypes = @(($listColumns | Where-Object { $_.name -ceq 'TipoEvento' }).choices)
$localDocs = @()
if (-not $SkipProtocols) {
    $builderBytes = [IO.File]::ReadAllBytes($builder)
    $localDocs = @(
        Get-ChildItem -LiteralPath $protocolDir -Filter '*.md' -File | Sort-Object Name | ForEach-Object {
            $meta = Get-DsaProtocolMetadata -FileStem $_.BaseName -Markdown (Get-Content -LiteralPath $_.FullName -Raw -Encoding utf8) -AllowedTypes $allowedTypes
            $hash = Get-DsaProtocolHash -MarkdownBytes ([IO.File]::ReadAllBytes($_.FullName)) -BuilderBytes $builderBytes
            [pscustomobject]@{ FileName = $meta.FileName; Hash = $hash; TipoEvento = $meta.TipoEvento; Version = $meta.Version }
        }
    )
    foreach ($doc in $localDocs) {
        Write-DsaLine Info "Protocolo $($doc.FileName) v$($doc.Version) — hash de la fuente $($doc.Hash.Substring(0, 12))…"
    }
}

# --- 3. Módulo y sesión de Graph ----------------------------------------------------------------

if ($LocalOnly) {
    Write-DsaLine Info 'Solo parte local (-LocalOnly): contrato y protocolos válidos; no se abrió sesión ni se leyó el tenant.'
    exit 0
}

if (-not (Get-Module -ListAvailable -Name 'Microsoft.Graph.Authentication')) {
    $install = 'Install-Module Microsoft.Graph.Authentication -Scope CurrentUser'
    if ($dryRun) {
        Write-DsaLine Warning "No está instalado el módulo Microsoft.Graph.Authentication; -WhatIf solo revisó la parte local. Para comparar con el tenant: $install"
        exit 0
    }
    Write-DsaLine Error "Falta el módulo Microsoft.Graph.Authentication. Instálalo con: $install"
    exit 3
}
Import-Module Microsoft.Graph.Authentication

$context = Get-MgContext
$missingScopes = if ($context) { Get-DsaMissingScopes -Granted @($context.Scopes) -Required $RequiredScopes } else { $RequiredScopes }
if (-not $context -or $context.AuthType -ne 'Delegated' -or $missingScopes.Count -gt 0) {
    if ($dryRun) {
        Write-Host '-WhatIf necesita una sesión de Graph para leer el tenant (solo lectura; no escribe nada). Para revisar solo la parte local usa -LocalOnly.' -ForegroundColor Yellow
    }
    Write-Host "Inicio de sesión delegado e interactivo con: $($RequiredScopes -join ', ')" -ForegroundColor Cyan
    Connect-MgGraph -Scopes $RequiredScopes -ContextScope Process -NoWelcome
}
Write-DsaLine Info "Sesión de Graph: $((Get-MgContext).Account)"

# --- 4. Sitios ----------------------------------------------------------------------------------

$site = Get-DsaSite -Url $SiteUrl
if (-not $site) {
    Write-DsaLine Error "No existe el sitio de la demo $SiteUrl. Créalo en el portal de SharePoint y vuelve a ejecutar."
    exit 4
}
$siteId = [string](Get-DsaValue $site 'id')
Write-DsaLine Exists "Sitio de la demo '$(Get-DsaValue $site 'displayName')'"

$controlSite = Get-DsaSite -Url $ControlSiteUrl
if (-not $controlSite) {
    Write-DsaLine Error "No existe el sitio de control $ControlSiteUrl. Este script no lo crea: créalo vacío en el portal de SharePoint (CA-06.2)."
}
else {
    $controlId = [string](Get-DsaValue $controlSite 'id')
    $controlLists = foreach ($list in (Get-DsaPaged -Uri "v1.0/sites/$controlId/lists?`$select=id,displayName,list")) {
        $info = Get-DsaValue $list 'list'
        $hidden = [bool](Get-DsaValue $info 'hidden')
        $count = 0
        if (-not $hidden) {
            $probe = Invoke-DsaGraph -Uri "v1.0/sites/$controlId/lists/$(Get-DsaValue $list 'id')/items?`$top=1&`$select=id"
            $count = @(Get-DsaValue $probe 'value').Where({ $null -ne $_ }).Count
        }
        [pscustomobject]@{ displayName = Get-DsaValue $list 'displayName'; template = Get-DsaValue $info 'template'; hidden = $hidden; itemCount = $count }
    }
    $emptiness = Test-DsaControlSiteEmpty -Lists @($controlLists)
    if ($emptiness.IsEmpty) {
        Write-DsaLine Exists "Sitio de control '$(Get-DsaValue $controlSite 'displayName')' (vacío)"
    }
    else {
        Write-DsaLine Error "El sitio de control no está vacío; tiene elementos en: $($emptiness.NonEmpty -join ', '). Vacíalo en el portal."
    }
}

# --- 5. Lista y biblioteca ----------------------------------------------------------------------

$siteLists = Get-DsaPaged -Uri "v1.0/sites/$siteId/lists?`$select=id,displayName,name,list"
$null = Initialize-DsaList -SiteId $siteId -DisplayName $ListName -Template 'genericList' -Columns $listColumns -SiteLists $siteLists
$libraryId = Initialize-DsaList -SiteId $siteId -DisplayName $LibraryName -Template 'documentLibrary' -Columns $libraryColumns -SiteLists $siteLists

# --- 6. Protocolos ------------------------------------------------------------------------------

if ($SkipProtocols) {
    Write-DsaLine Info 'Protocolos omitidos (-SkipProtocols).'
}
else {
    $remote = @()
    $driveId = $null
    if ($libraryId) {
        $driveId = [string](Get-DsaValue (Invoke-DsaGraph -Uri "v1.0/sites/$siteId/lists/$libraryId/drive?`$select=id") 'id')
        $items = Get-DsaPaged -Uri "v1.0/sites/$siteId/lists/$libraryId/items?`$select=id&`$expand=fields(`$select=FileLeafRef,HashFuente)"
        $remote = ConvertFrom-DsaLibraryItems -Items $items
    }
    $plan = @(Get-DsaProtocolPlan -Local $localDocs -Remote $remote)
    $pending = @($plan | Where-Object { $_.Action -in 'Upload', 'Replace' })

    if ($pending.Count -gt 0 -and -not $dryRun) {
        # Se genera solo si hay algo que subir: así una ejecución sin cambios no toca protocols/dist.
        $python = @(
            (Join-Path $repoRoot '.venv' 'Scripts' 'python.exe'),
            (Join-Path $repoRoot '.venv' 'bin' 'python')
        ) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
        if (-not $python) {
            Write-DsaLine Error 'No está el entorno .venv. Créalo con: python -m venv .venv; .venv/Scripts/python -m pip install -r requirements-dev.txt'
            exit 5
        }
        & $python $builder --out $distDir | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-DsaLine Error "build-protocols.py terminó con código $LASTEXITCODE."
            exit 5
        }
    }

    foreach ($step in $plan) {
        $label = "  documento $($step.FileName)"
        switch ($step.Action) {
            'Skip' { Write-DsaLine Exists "$label (sin cambios)" }
            'Extra' { Write-DsaLine Warning "$label está en '$LibraryName' pero no en protocols/; no se borra." }
            { $_ -in 'Upload', 'Replace' } {
                $verb = if ($step.Action -eq 'Upload') { 'subir' } else { 'reemplazar (cambió la fuente)' }
                if ($dryRun) { Write-DsaLine WhatIf "$label`: $verb"; continue }
                $file = Join-Path $distDir $step.FileName
                if (-not (Test-Path -LiteralPath $file)) { Write-DsaLine Error "$label`: no se generó $file"; continue }
                $encoded = [uri]::EscapeDataString($step.FileName)
                $driveItem = Invoke-DsaGraph -Method PUT -Uri "v1.0/drives/$driveId/root:/$encoded`:/content" -InputFilePath $file -ContentType $DocxMime
                $listItem = Invoke-DsaGraph -Uri "v1.0/drives/$driveId/items/$(Get-DsaValue $driveItem 'id')/listItem?`$select=id"
                $null = Invoke-DsaGraph -Method PATCH -Uri "v1.0/sites/$siteId/lists/$libraryId/items/$(Get-DsaValue $listItem 'id')/fields" -Body ([ordered]@{
                        TipoEvento = $step.Local.TipoEvento
                        Version    = $step.Local.Version
                        HashFuente = $step.Local.Hash
                    })
                if ($step.Action -eq 'Upload') { Write-DsaLine Created "$label (v$($step.Local.Version))" }
                else { Write-DsaLine Updated "$label reemplazado (v$($step.Local.Version))" }
            }
        }
    }
}

# --- 7. Resumen ---------------------------------------------------------------------------------

Write-Host ''
$summary = "Resumen: $($script:Counts.Created) creados, $($script:Counts.Updated) completados, $($script:Counts.Exists) ya existían"
if ($dryRun) { $summary += ", $($script:Counts.WhatIf) cambios pendientes (-WhatIf)" }
$summary += ", $($script:Counts.Warning) avisos, $($script:Counts.Error) errores."
$color = if ($script:Counts.Error -gt 0) { 'Red' } elseif ($script:Counts.Warning -gt 0) { 'Yellow' } else { 'Green' }
Write-Host $summary -ForegroundColor $color
if (-not $dryRun -and $script:Counts.Error -eq 0 -and $script:Counts.Created -eq 0 -and $script:Counts.Updated -eq 0) {
    Write-Host 'Sin cambios: el tenant ya cumple el contrato (CA-07.2).' -ForegroundColor Green
}
exit ([int]($script:Counts.Error -gt 0))
