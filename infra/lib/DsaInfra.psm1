#Requires -Version 7.0
# Funciones compartidas de los scripts de infra/ (T-019, T-020).
# Las funciones puras se prueban con Pester en infra/tests/. Toda llamada a la CLI de Azure pasa
# por Invoke-DsaAz para poder simularla en las pruebas. Ninguna función imprime ni guarda secretos.

Set-StrictMode -Version Latest

# Proveedores de recursos que usa la plantilla (plan §10, R-20).
$script:RequiredProviders = @(
    'Microsoft.Devices'
    'Microsoft.Web'
    'Microsoft.KeyVault'
    'Microsoft.Storage'
    'Microsoft.Insights'
    'Microsoft.OperationalInsights'
    'Microsoft.ManagedIdentity'
)

# Archivos de contrato que la Function lee desde DSA_CONTRACTS_DIR (_contracts/ en el paquete).
$script:ContractFiles = @(
    'schemas/evento-dispositivo.schema.json'
    'data/zonas.json'
    'sharepoint/columnas.json'
)

# Escenarios de always ready (ADR-005 §2).
$script:AlwaysReadyScenarios = [ordered]@{
    reposo = 0
    ensayo = 1
    sesion = 1
}

# Sites.Selected (aplicación): https://learn.microsoft.com/graph/permissions-reference#sitesselected
$script:SitesSelectedAppRoleId = '883ea226-0bf2-4a8f-9f9d-92c9162a727d'
$script:GraphAppId = '00000003-0000-0000-c000-000000000000'

function Invoke-DsaAz {
    <#
    .SYNOPSIS
    Ejecuta la CLI de Azure con los argumentos dados y devuelve la salida. Falla si el código no es 0.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory, ValueFromRemainingArguments)][string[]] $Arguments)
    $output = & az @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "az $($Arguments[0..([Math]::Min(2, $Arguments.Count - 1))] -join ' ') terminó con código $LASTEXITCODE"
    }
    return $output
}

function Get-DsaRequiredProviders {
    [CmdletBinding()]
    [OutputType([string[]])]
    param()
    return $script:RequiredProviders.Clone()
}

function Get-DsaContractFiles {
    [CmdletBinding()]
    [OutputType([string[]])]
    param()
    return $script:ContractFiles.Clone()
}

function Test-DsaGuid {
    [CmdletBinding()]
    [OutputType([bool])]
    param([AllowEmptyString()][string] $Value)
    $parsed = [guid]::Empty
    return [guid]::TryParse($Value, [ref] $parsed) -and $parsed -ne [guid]::Empty
}

function Test-DsaResourceGroupName {
    <#
    .SYNOPSIS
    Valida un nombre de grupo de recursos: 1-90 caracteres alfanuméricos, guion, guion bajo, punto y paréntesis; no termina en punto.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([AllowEmptyString()][string] $Name)
    return ($Name -match '^[\w\-\.\(\)]{1,90}$') -and -not $Name.EndsWith('.')
}

function Get-DsaAlwaysReadyCount {
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Mandatory)][ValidateSet('reposo', 'ensayo', 'sesion')][string] $Scenario)
    return [int] $script:AlwaysReadyScenarios[$Scenario]
}

function Get-DsaProvidersToRegister {
    <#
    .SYNOPSIS
    Devuelve los proveedores requeridos cuyo estado no es Registered.
    .PARAMETER State
    Tabla espacio de nombres -> estado de registro, tal como la devuelve 'az provider show'.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)][hashtable] $State)
    return @($script:RequiredProviders | Where-Object { $State[$_] -ne 'Registered' })
}

function New-DsaDeploymentArguments {
    <#
    .SYNOPSIS
    Arma los argumentos de 'az deployment group create|what-if'. Omite los parámetros vacíos.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][ValidateSet('create', 'what-if')][string] $Mode,
        [Parameter(Mandatory)][string] $ResourceGroup,
        [Parameter(Mandatory)][string] $TemplateFile,
        [Parameter(Mandatory)][string] $ParametersFile,
        [string] $DeploymentName = 'dsa-main',
        [System.Collections.IDictionary] $Parameters = @{}
    )
    $result = @(
        'deployment', 'group', $Mode,
        '--resource-group', $ResourceGroup,
        '--name', $DeploymentName,
        '--template-file', $TemplateFile,
        '--parameters', $ParametersFile
    )
    foreach ($key in ($Parameters.Keys | Sort-Object)) {
        $value = $Parameters[$key]
        if ($null -ne $value -and "$value" -ne '') {
            $result += @('--parameters', "$key=$value")
        }
    }
    if ($Mode -eq 'create') { $result += @('--output', 'json') }
    return $result
}

function Format-DsaAdminCommands {
    <#
    .SYNOPSIS
    Devuelve los dos comandos del administrador del tenant (CA-06.4) con el client ID y el object ID de id-dsa-func.
    El ID del sitio queda como marcador <siteId>. Mismo texto que docs/admin-sites-selected.md.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string] $ClientId,
        [Parameter(Mandatory)][string] $ObjectId,
        [string] $DisplayName = 'id-dsa-func',
        [string] $SiteId = '<siteId>'
    )
    $lines = @(
        '# Sesión del administrador (SharePoint Administrator o superior, miembro del sitio de la demo):'
        "Connect-MgGraph -Scopes 'Application.Read.All','AppRoleAssignment.ReadWrite.All','Sites.FullControl.All'"
        ''
        '# Comando 1: asignar el rol de aplicación Sites.Selected de Microsoft Graph a la identidad administrada'
        "New-MgServicePrincipalAppRoleAssignment -ServicePrincipalId '$ObjectId' -PrincipalId '$ObjectId' -ResourceId (Get-MgServicePrincipal -Filter `"appId eq '$($script:GraphAppId)'`").Id -AppRoleId '$($script:SitesSelectedAppRoleId)'"
        ''
        '# Comando 2: conceder write solo sobre el sitio de la demo (POST /sites/{siteId}/permissions)'
        "New-MgSitePermission -SiteId '$SiteId' -BodyParameter @{ roles = @('write'); grantedToIdentities = @(@{ application = @{ id = '$ClientId'; displayName = '$DisplayName' } }) }"
    )
    return ($lines -join [Environment]::NewLine)
}

function Copy-DsaContracts {
    <#
    .SYNOPSIS
    Copia los contratos versionados a <Destination> (por defecto function/_contracts) para empaquetarlos con la Function.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][string] $RepoRoot,
        [string] $Destination
    )
    if (-not $Destination) { $Destination = Join-Path $RepoRoot 'function/_contracts' }
    $copied = @()
    foreach ($relative in $script:ContractFiles) {
        $source = Join-Path $RepoRoot $relative
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
            throw "Falta el contrato $relative"
        }
        if ($PSCmdlet.ShouldProcess($Destination, "Copiar $relative")) {
            New-Item -ItemType Directory -Path $Destination -Force | Out-Null
            $target = Join-Path $Destination (Split-Path $relative -Leaf)
            Copy-Item -LiteralPath $source -Destination $target -Force
            $copied += $target
        }
    }
    return $copied
}

function Get-DsaPackageFiles {
    <#
    .SYNOPSIS
    Lista los archivos de function/ que entran en el paquete, sin cachés, entornos locales ni configuración local.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)][string] $FunctionDir)
    $excluded = '(^|[\\/])(__pycache__|\.venv|\.python_packages|\.pytest_cache|tests)([\\/]|$)|local\.settings\.json$|\.pyc$'
    $root = (Resolve-Path -LiteralPath $FunctionDir).Path
    return @(Get-ChildItem -LiteralPath $root -Recurse -File |
            ForEach-Object { [IO.Path]::GetRelativePath($root, $_.FullName) } |
            Where-Object { $_ -notmatch $excluded } |
            Sort-Object)
}

function New-DsaFunctionPackage {
    <#
    .SYNOPSIS
    Copia los contratos a function/_contracts y genera el zip del paquete. Devuelve la ruta del zip.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string] $RepoRoot,
        [Parameter(Mandatory)][string] $OutputZip
    )
    $functionDir = Join-Path $RepoRoot 'function'
    Copy-DsaContracts -RepoRoot $RepoRoot | Out-Null
    $staging = Join-Path ([IO.Path]::GetTempPath()) ("dsa-pkg-" + [guid]::NewGuid().ToString('N'))
    try {
        foreach ($relative in (Get-DsaPackageFiles -FunctionDir $functionDir)) {
            $target = Join-Path $staging $relative
            New-Item -ItemType Directory -Path (Split-Path $target -Parent) -Force | Out-Null
            Copy-Item -LiteralPath (Join-Path $functionDir $relative) -Destination $target
        }
        if (Test-Path -LiteralPath $OutputZip) { Remove-Item -LiteralPath $OutputZip -Force }
        Compress-Archive -Path (Join-Path $staging '*') -DestinationPath $OutputZip
    }
    finally {
        if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force }
    }
    return $OutputZip
}

function Get-DsaAlwaysReadyCommand {
    <#
    .SYNOPSIS
    Argumentos de az para fijar always ready de function:<nombre>. 0 elimina la designación.
    https://learn.microsoft.com/azure/azure-functions/flex-consumption-how-to#set-always-ready-instance-counts
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][string] $ResourceGroup,
        [Parameter(Mandatory)][string] $FunctionAppName,
        [Parameter(Mandatory)][ValidateRange(0, 1)][int] $Count,
        [string] $FunctionName = 'ingest_event'
    )
    $base = @('functionapp', 'scale', 'config', 'always-ready')
    $target = @('--resource-group', $ResourceGroup, '--name', $FunctionAppName)
    if ($Count -eq 0) {
        return $base + @('delete') + $target + @('--setting-names', "function:$FunctionName", '--output', 'none')
    }
    return $base + @('set') + $target + @('--settings', "function:$FunctionName=$Count", '--output', 'none')
}

function Set-DsaAlwaysReady {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string] $ResourceGroup,
        [Parameter(Mandatory)][string] $FunctionAppName,
        [Parameter(Mandatory)][ValidateSet('reposo', 'ensayo', 'sesion')][string] $Scenario
    )
    $count = Get-DsaAlwaysReadyCount -Scenario $Scenario
    $azArgs = Get-DsaAlwaysReadyCommand -ResourceGroup $ResourceGroup -FunctionAppName $FunctionAppName -Count $count
    if ($PSCmdlet.ShouldProcess($FunctionAppName, "always ready = $count ($Scenario)")) {
        Invoke-DsaAz @azArgs | Out-Null
    }
    return $count
}

function Get-DsaRotationPlan {
    <#
    .SYNOPSIS
    Orden de la rotación sin corte de la clave de func-reader (ADR-005 §3).
    1) renovar la clave que se va a usar (hoy no la usa nadie), 2) reescribir el secreto con esa clave,
    3) forzar la recarga de referencias de Key Vault, 4) renovar la otra clave (invalida la anterior).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param([Parameter(Mandatory)][ValidateSet('primary', 'secondary')][string] $TargetKey)
    $other = if ($TargetKey -eq 'primary') { 'secondary' } else { 'primary' }
    return @(
        [pscustomobject]@{ Step = 1; Action = 'renew-key'; Key = $TargetKey }
        [pscustomobject]@{ Step = 2; Action = 'write-secret'; Key = $TargetKey }
        [pscustomobject]@{ Step = 3; Action = 'refresh-references'; Key = $TargetKey }
        [pscustomobject]@{ Step = 4; Action = 'renew-key'; Key = $other }
    )
}

function Get-DsaRenewKeyCommand {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][string] $ResourceGroup,
        [Parameter(Mandatory)][string] $IotHubName,
        [Parameter(Mandatory)][ValidateSet('primary', 'secondary')][string] $Key,
        [string] $PolicyName = 'func-reader'
    )
    # La salida de renew-key incluye las claves: se descarta con --output none.
    return @('iot', 'hub', 'policy', 'renew-key', '--resource-group', $ResourceGroup, '--hub-name', $IotHubName,
        '--name', $PolicyName, '--renew-key', $Key, '--output', 'none')
}

function Get-DsaWriteSecretCommand {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][string] $ResourceGroup,
        [Parameter(Mandatory)][string] $IotHubName,
        [Parameter(Mandatory)][string] $KeyVaultName,
        [Parameter(Mandatory)][ValidateSet('primary', 'secondary')][string] $Key,
        [Parameter(Mandatory)][string] $TemplateFile
    )
    # El secreto lo compone Azure Resource Manager con listkeys(): la clave nunca pasa por esta consola.
    return @('deployment', 'group', 'create', '--resource-group', $ResourceGroup, '--name', 'dsa-iothub-secret',
        '--template-file', $TemplateFile,
        '--parameters', "iotHubName=$IotHubName", "keyVaultName=$KeyVaultName", "keySlot=$Key",
        '--output', 'none')
}

function Get-DsaRefreshReferencesCommand {
    <#
    .SYNOPSIS
    POST .../config/configreferences/appsettings/refresh
    https://learn.microsoft.com/azure/app-service/app-service-key-vault-references#understand-rotation
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)][string] $FunctionAppId)
    $uri = "https://management.azure.com$FunctionAppId/config/configreferences/appsettings/refresh?api-version=2022-03-01"
    return @('rest', '--method', 'post', '--uri', $uri, '--output', 'none')
}

function Invoke-DsaKeyRotation {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string] $ResourceGroup,
        [Parameter(Mandatory)][string] $IotHubName,
        [Parameter(Mandatory)][string] $KeyVaultName,
        [Parameter(Mandatory)][string] $FunctionAppId,
        [Parameter(Mandatory)][string] $SecretTemplateFile,
        [Parameter(Mandatory)][ValidateSet('primary', 'secondary')][string] $TargetKey
    )
    foreach ($step in (Get-DsaRotationPlan -TargetKey $TargetKey)) {
        $azArgs = switch ($step.Action) {
            'renew-key' { Get-DsaRenewKeyCommand -ResourceGroup $ResourceGroup -IotHubName $IotHubName -Key $step.Key }
            'write-secret' {
                Get-DsaWriteSecretCommand -ResourceGroup $ResourceGroup -IotHubName $IotHubName `
                    -KeyVaultName $KeyVaultName -Key $step.Key -TemplateFile $SecretTemplateFile
            }
            'refresh-references' { Get-DsaRefreshReferencesCommand -FunctionAppId $FunctionAppId }
        }
        if ($PSCmdlet.ShouldProcess($IotHubName, "Paso $($step.Step): $($step.Action) ($($step.Key))")) {
            Invoke-DsaAz @azArgs | Out-Null
            Write-Host "Paso $($step.Step) listo: $($step.Action) ($($step.Key))"
        }
    }
}

Export-ModuleMember -Function @(
    'Invoke-DsaAz'
    'Get-DsaRequiredProviders'
    'Get-DsaContractFiles'
    'Test-DsaGuid'
    'Test-DsaResourceGroupName'
    'Get-DsaAlwaysReadyCount'
    'Get-DsaProvidersToRegister'
    'New-DsaDeploymentArguments'
    'Format-DsaAdminCommands'
    'Copy-DsaContracts'
    'Get-DsaPackageFiles'
    'New-DsaFunctionPackage'
    'Get-DsaAlwaysReadyCommand'
    'Set-DsaAlwaysReady'
    'Get-DsaRotationPlan'
    'Get-DsaRenewKeyCommand'
    'Get-DsaWriteSecretCommand'
    'Get-DsaRefreshReferencesCommand'
    'Invoke-DsaKeyRotation'
)
