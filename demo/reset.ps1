#Requires -Version 7.0
<#
.SYNOPSIS
    T-046 (HU-14 CA-14.2): deja la demo en su estado inicial en ≤ 2 minutos.

.DESCRIPTION
    1. Manda a la papelera de reciclaje del sitio los elementos de 'Eventos de seguridad' con
       EsPrueba = Sí (o todos con -All). Nunca hace un borrado definitivo ni vacía la papelera.
    2. Vacía las tablas 'dedup' y 'ratelimit' de Table Storage (ADR-006) para que el primer evento
       de la demo abra un incidente.
    Muestra el tiempo total frente al objetivo de 2 minutos.

    Identidad: la de Daniel, nunca la de la Function (CA-14.2).
    - Graph delegado, sesión interactiva, ámbito Sites.ReadWrite.All: es el menor privilegio que
      Learn indica para borrar un listItem (DELETE /sites/{id}/lists/{id}/items/{id}).
      https://learn.microsoft.com/graph/api/listitem-delete#permissions
    - Azure: la sesión de 'az' de Daniel con el rol Storage Table Data Contributor sobre la cuenta
      (lo asigna Bicep con operatorPrincipalId, ADR-006). La consulta usa
      'az storage entity query --auth-mode login'. El borrado usa la API REST de Delete Entity con
      un token de Microsoft Entra ID de la misma sesión (az account get-access-token), porque la
      PartitionKey de dedup lleva '|' y, en Windows, az.cmd la pasa por cmd.exe, que la interpreta
      como una tubería (comprobado en esta máquina). Además evita un proceso de az por entidad.
      https://learn.microsoft.com/rest/api/storageservices/delete-entity1
      https://learn.microsoft.com/rest/api/storageservices/authorize-with-azure-active-directory
    Ningún token se escribe en archivos ni en pantalla.

    RIESGO: la página de Learn de DELETE listItem no dice explícitamente que el elemento va a la
    papelera; una respuesta de Microsoft Q&A indica que sí. Se verifica en la primera ejecución
    real (T-046: "los elementos aparecen en la papelera"). Si no fuera así, este script debe
    cambiar al método recycle() de la API REST de SharePoint antes de usarse.

.PARAMETER All
    Manda a la papelera todos los elementos, no solo los de prueba.

.EXAMPLE
    pwsh -File demo/reset.ps1
    pwsh -File demo/reset.ps1 -All -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [switch] $All,
    [string] $SiteUrl,
    [string] $ListName,
    [string] $ResourceGroup,
    [string] $StorageAccount,
    [string] $DeploymentName = 'dsa-main',
    [string] $EnvFile,
    [switch] $SkipList,
    [switch] $SkipStorage
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

$dryRun = [bool]$WhatIfPreference
$WhatIfPreference = $false

$stopwatch = [Diagnostics.Stopwatch]::StartNew()
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
Import-Module (Join-Path $PSScriptRoot 'ResetLogic.psm1') -Force

$RequiredScopes = @('Sites.ReadWrite.All')
$StorageResource = 'https://storage.azure.com/'
$script:Errors = 0

function Write-DsaLine {
    param([string] $Status, [string] $Message)
    $line = Format-DsaLine -Status $Status -Message $Message
    if ($Status -eq 'Error') { $script:Errors++ }
    Write-Host $line.Text -ForegroundColor $line.Color
}

function Invoke-DsaAzCli {
    param([Parameter(Mandatory)][string[]] $Arguments)
    $output = & az @Arguments
    if ($LASTEXITCODE -ne 0) { throw "az $($Arguments[0..2] -join ' ') terminó con código $LASTEXITCODE" }
    return ($output -join "`n")
}

Write-Host ''
Write-Host 'Reinicio de la demo (T-046)' -ForegroundColor White
if ($dryRun) { Write-Host 'Modo -WhatIf: se lee el estado, no se borra nada.' -ForegroundColor Yellow }

if (-not $EnvFile) { $EnvFile = Join-Path $repoRoot '.env' }
$dotEnv = if (Test-Path -LiteralPath $EnvFile) { ConvertFrom-DsaDotEnv -Lines (Get-Content -LiteralPath $EnvFile) } else { @{} }
$processEnv = @{}
foreach ($name in 'DSA_SITE_URL', 'DSA_LIST_NAME', 'DSA_RESOURCE_GROUP', 'DSA_STORAGE_ACCOUNT') {
    $processEnv[$name] = [Environment]::GetEnvironmentVariable($name)
}
$SiteUrl = Resolve-DsaSetting -Explicit $SiteUrl -Name 'DSA_SITE_URL' -DotEnv $dotEnv -ProcessEnv $processEnv
$ListName = Resolve-DsaSetting -Explicit $ListName -Name 'DSA_LIST_NAME' -DotEnv $dotEnv -ProcessEnv $processEnv -Default 'Eventos de seguridad'
$ResourceGroup = Resolve-DsaSetting -Explicit $ResourceGroup -Name 'DSA_RESOURCE_GROUP' -DotEnv $dotEnv -ProcessEnv $processEnv
$StorageAccount = Resolve-DsaSetting -Explicit $StorageAccount -Name 'DSA_STORAGE_ACCOUNT' -DotEnv $dotEnv -ProcessEnv $processEnv

# --- 1. Lista: elementos a la papelera ----------------------------------------------------------

if ($SkipList) {
    Write-DsaLine Info 'Lista omitida (-SkipList).'
}
elseif (-not $SiteUrl) {
    Write-DsaLine Error 'Falta la URL del sitio: usa -SiteUrl o define DSA_SITE_URL en .env.'
}
elseif (-not (Get-Module -ListAvailable -Name 'Microsoft.Graph.Authentication')) {
    Write-DsaLine Error 'Falta el módulo Microsoft.Graph.Authentication. Instálalo con: Install-Module Microsoft.Graph.Authentication -Scope CurrentUser'
}
else {
    Import-Module Microsoft.Graph.Authentication
    $context = Get-MgContext
    $missing = if ($context) { Get-DsaMissingScopes -Granted @($context.Scopes) -Required $RequiredScopes } else { $RequiredScopes }
    if (-not $context -or $context.AuthType -ne 'Delegated' -or $missing.Count -gt 0) {
        Write-Host "Inicio de sesión delegado e interactivo con: $($RequiredScopes -join ', ')" -ForegroundColor Cyan
        Connect-MgGraph -Scopes $RequiredScopes -ContextScope Process -NoWelcome
    }
    $invoker = { param($u) Invoke-MgGraphRequest -Method GET -Uri $u -OutputType HashTable }

    $site = Invoke-MgGraphRequest -Method GET -Uri "v1.0/sites/$(ConvertTo-DsaSitePath -SiteUrl $SiteUrl)?`$select=id" -OutputType HashTable
    $siteId = [string](Get-DsaValue $site 'id')
    $lists = Invoke-DsaGraphPaged -Uri "v1.0/sites/$siteId/lists?`$select=id,displayName" -Invoker $invoker
    $list = Find-DsaListByDisplayName -Lists $lists -DisplayName $ListName
    if (-not $list) {
        Write-DsaLine Error "No existe la lista '$ListName'. Ejecuta antes sharepoint/provision.ps1."
    }
    else {
        $listId = [string](Get-DsaValue $list 'id')
        $items = Invoke-DsaGraphPaged -Invoker $invoker -Uri "v1.0/sites/$siteId/lists/$listId/items?`$select=id&`$expand=fields(`$select=EventId,Estado,EsPrueba)&`$top=500"
        $targets = Select-DsaResetItems -Items $items -All:$All
        $scope = if ($All) { 'todos los elementos' } else { 'elementos con EsPrueba = Sí' }
        Write-DsaLine Info "Lista '$ListName': $(@($items).Count) elementos; a la papelera: $($targets.Count) ($scope)."
        foreach ($target in $targets) {
            $label = "  elemento $($target.Id) · EventId $($target.EventId) · $($target.Estado)"
            if ($dryRun) { Write-DsaLine WhatIf "$label → papelera"; continue }
            try {
                # DELETE de Graph sobre listItem: va a la papelera del sitio (ver RIESGO en la ayuda).
                Invoke-MgGraphRequest -Method DELETE -Uri "v1.0/sites/$siteId/lists/$listId/items/$($target.Id)" | Out-Null
                Write-DsaLine Updated "$label → papelera"
            }
            catch {
                if ((Get-DsaHttpStatus $_) -eq 404) { Write-DsaLine Exists "$label ya no estaba" }
                else { Write-DsaLine Error "$label`: $($_.Exception.Message)" }
            }
        }
    }
}

# --- 2. Table Storage: dedup y ratelimit vacías ------------------------------------------------

if ($SkipStorage) {
    Write-DsaLine Info 'Table Storage omitido (-SkipStorage).'
}
elseif (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    Write-DsaLine Error 'No está la CLI de Azure (az). Instálala: https://learn.microsoft.com/cli/azure/install-azure-cli'
}
else {
    try {
        if (-not $StorageAccount) {
            if (-not $ResourceGroup) { throw 'Falta la cuenta: usa -StorageAccount o define DSA_RESOURCE_GROUP en .env.' }
            $StorageAccount = (Invoke-DsaAzCli @('deployment', 'group', 'show', '--resource-group', $ResourceGroup,
                    '--name', $DeploymentName, '--query', 'properties.outputs.storageAccountName.value', '--output', 'tsv')).Trim()
        }
        Write-DsaLine Info "Cuenta de almacenamiento: $StorageAccount"
        $token = $null
        if (-not $dryRun) {
            $token = (Invoke-DsaAzCli @('account', 'get-access-token', '--resource', $StorageResource, '--query', 'accessToken', '--output', 'tsv')).Trim()
        }
        foreach ($table in (Get-DsaResetTables)) {
            $entities = [System.Collections.Generic.List[object]]::new()
            $marker = $null
            do {
                $page = ConvertFrom-DsaEntityQuery -Json (Invoke-DsaAzCli (Get-DsaEntityQueryArguments -Account $StorageAccount -Table $table -Marker $marker))
                foreach ($entity in $page.Entities) { $entities.Add($entity) }
                $marker = $page.Marker
            } while ($marker)

            if ($entities.Count -eq 0) { Write-DsaLine Exists "  tabla $table ya estaba vacía"; continue }
            if ($dryRun) { Write-DsaLine WhatIf "  tabla $table`: se borrarían $($entities.Count) entidades"; continue }

            $headers = Get-DsaTableDeleteHeaders -AccessToken $token
            $uris = @($entities | ForEach-Object { Get-DsaTableEntityUri -Account $StorageAccount -Table $table -PartitionKey $_.PartitionKey -RowKey $_.RowKey })
            # En paralelo para cumplir los 2 minutos aunque una ráfaga haya dejado decenas de filas.
            $failures = @($uris | ForEach-Object -ThrottleLimit 8 -Parallel {
                    try { Invoke-RestMethod -Method Delete -Uri $_ -Headers $using:headers | Out-Null }
                    catch {
                        $response = $_.Exception.Response
                        $code = if ($response) { [int]$response.StatusCode } else { 0 }
                        if ($code -ne 404) { if ($code) { "$code" } else { 'sin respuesta' } }
                    }
                })
            if ($failures.Count -gt 0) {
                Write-DsaLine Error "  tabla $table`: $($failures.Count) de $($entities.Count) entidades no se borraron (códigos: $(($failures | Sort-Object -Unique) -join ', '))"
            }
            else {
                Write-DsaLine Updated "  tabla $table`: $($entities.Count) entidades borradas"
            }
        }
    }
    catch {
        Write-DsaLine Error "Table Storage: $($_.Exception.Message)"
    }
    finally {
        $token = $null
    }
}

# --- 3. Tiempo ----------------------------------------------------------------------------------

$stopwatch.Stop()
$elapsed = Format-DsaElapsed -Elapsed $stopwatch.Elapsed
Write-Host ''
Write-Host "Tiempo total: $($elapsed.Text)" -ForegroundColor $elapsed.Color
if ($script:Errors -gt 0) {
    Write-Host "Terminó con $($script:Errors) errores." -ForegroundColor Red
    exit 1
}
if ($dryRun) { Write-Host 'Fin de -WhatIf: no se cambió nada.' -ForegroundColor Yellow }
else { Write-Host 'Demo en estado inicial.' -ForegroundColor Green }
exit 0
