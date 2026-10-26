#Requires -Version 7.0
<#
.SYNOPSIS
Despliega la infraestructura de la demo y publica la Function (T-019, CA-04.3, CA-06.4).

.DESCRIPTION
1. Comprueba la sesión de az (no inicia sesión por ti).
2. Registra los proveedores de recursos que faltan.
3. Crea el grupo de recursos si no existe (en -ResourceGroupLocation; los recursos van en -Location).
4. Despliega infra/main.bicep con infra/main.bicepparam (o solo what-if con -WhatIf).
5. Empaqueta function/ con los contratos en function/_contracts/ y lo publica (se omite con -SkipPublish
   o si todavía no existe function/function_app.py).
6. Imprime el client ID y el object ID de id-dsa-func y los dos comandos del administrador del tenant.
No escribe ningún identificador ni secreto en archivos versionados.

.EXAMPLE
./infra/deploy.ps1 -WhatIf
./infra/deploy.ps1 -ResourceGroup rg-dsa-demo -Location eastus2
./infra/deploy.ps1 -IotHubSku B1 -AlwaysReadyCount 1
#>
[CmdletBinding()]
param(
    [string] $ResourceGroup = 'rg-dsa-demo',
    [string] $Location = 'eastus2',
    [string] $ResourceGroupLocation,
    [ValidateSet('F1', 'B1')][string] $IotHubSku = 'F1',
    [ValidateRange(0, 1)][int] $AlwaysReadyCount = 0,
    [string] $GraphSiteId = '',
    [string] $GraphListId = '',
    [string] $AgentFlowUrl = '',
    [switch] $SkipOperatorRoles,
    [switch] $SkipPublish,
    [switch] $WhatIf
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib/DsaInfra.psm1') -Force

$repoRoot = Split-Path $PSScriptRoot -Parent
$template = Join-Path $PSScriptRoot 'main.bicep'
$paramsFile = Join-Path $PSScriptRoot 'main.bicepparam'
if (-not $ResourceGroupLocation) { $ResourceGroupLocation = $Location }

if (-not (Test-DsaResourceGroupName -Name $ResourceGroup)) { throw "Nombre de grupo de recursos no válido: $ResourceGroup" }
if ($AgentFlowUrl -match 'sig=') { throw 'La URL del flujo no debe llevar firma SAS (sig=); DisparoAgente usa Entra ID (ADR-003).' }

# 1. Sesión
$account = Invoke-DsaAz account show --output json | ConvertFrom-Json
Write-Host "Suscripción: $($account.name)"

# 2. Proveedores
$state = @{}
foreach ($ns in Get-DsaRequiredProviders) {
    $state[$ns] = (Invoke-DsaAz provider show --namespace $ns --query registrationState --output tsv)
}
$pending = Get-DsaProvidersToRegister -State $state
foreach ($ns in $pending) {
    if ($WhatIf) { Write-Host "[what-if] Se registraría el proveedor $ns"; continue }
    Write-Host "Registrando $ns..."
    Invoke-DsaAz provider register --namespace $ns --wait --output none | Out-Null
}

# 3. Grupo de recursos
$exists = (Invoke-DsaAz group exists --name $ResourceGroup) -eq 'true'
if (-not $exists) {
    if ($WhatIf) {
        Write-Host "[what-if] Se crearía el grupo $ResourceGroup en $ResourceGroupLocation. what-if de la plantilla necesita el grupo; termina aquí."
        return
    }
    Invoke-DsaAz group create --name $ResourceGroup --location $ResourceGroupLocation --output none | Out-Null
}

# 4. Plantilla
$operatorId = ''
if (-not $SkipOperatorRoles) {
    $operatorId = Invoke-DsaAz ad signed-in-user show --query id --output tsv
}
$parameters = [ordered]@{
    location            = $Location
    iotHubSku           = $IotHubSku
    alwaysReadyCount    = $AlwaysReadyCount
    operatorPrincipalId = $operatorId
    graphSiteId         = $GraphSiteId
    graphListId         = $GraphListId
    agentFlowUrl        = $AgentFlowUrl
}
$mode = if ($WhatIf) { 'what-if' } else { 'create' }
$deployArgs = New-DsaDeploymentArguments -Mode $mode -ResourceGroup $ResourceGroup -TemplateFile $template `
    -ParametersFile $paramsFile -Parameters $parameters
if ($WhatIf) {
    & az @deployArgs
    if ($LASTEXITCODE -ne 0) { throw 'what-if terminó con errores.' }
    return
}
$deployment = Invoke-DsaAz @deployArgs | ConvertFrom-Json
$out = $deployment.properties.outputs

# 5. Paquete de la Function
if ($SkipPublish) {
    Write-Host 'Publicación omitida (-SkipPublish).'
}
elseif (-not (Test-Path (Join-Path $repoRoot 'function/function_app.py'))) {
    Write-Host 'Publicación omitida: todavía no existe function/function_app.py.'
}
else {
    $zip = Join-Path ([IO.Path]::GetTempPath()) 'dsa-function.zip'
    New-DsaFunctionPackage -RepoRoot $repoRoot -OutputZip $zip | Out-Null
    Write-Host "Publicando $($out.functionAppName.value)..."
    Invoke-DsaAz functionapp deployment source config-zip --resource-group $ResourceGroup `
        --name $out.functionAppName.value --src $zip --build-remote true --output none | Out-Null
    Remove-Item -LiteralPath $zip -Force
}

# 6. Resumen (identificadores públicos, sin secretos)
$clientId = $out.identityClientId.value
$objectId = $out.identityPrincipalId.value
Write-Host ''
Write-Host "Function App:        $($out.functionAppName.value)"
Write-Host "IoT Hub:             $($out.iotHubName.value)"
Write-Host "Key Vault:           $($out.keyVaultName.value)"
Write-Host "Identidad:           $($out.identityName.value)"
Write-Host "  client ID (appId): $clientId   -> comando 2 de Sites.Selected"
Write-Host "  object ID:         $objectId   -> comando 1 y disparador de DisparoAgente"
Write-Host ''
Write-Host 'Comandos del administrador del tenant (docs/admin-sites-selected.md). Sustituye <siteId>:'
Write-Host (Format-DsaAdminCommands -ClientId $clientId -ObjectId $objectId)
Write-Host ''
Write-Host "Dispositivos: az iot hub device-identity create --hub-name $($out.iotHubName.value) --device-id sim-01 --auth-type login"
