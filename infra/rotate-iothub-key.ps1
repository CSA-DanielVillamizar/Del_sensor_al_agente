#Requires -Version 7.0
<#
.SYNOPSIS
Rota la clave de la política func-reader de IoT Hub sin cortar la ingesta (T-020, ADR-005 §3).

.DESCRIPTION
1) Renueva la clave -TargetKey (hoy sin uso). 2) Reescribe el secreto iothub-func-reader con esa clave
desplegando infra/modules/iothub-secret.bicep (Azure Resource Manager compone el valor con listkeys; la
clave nunca pasa por esta consola). 3) Fuerza la recarga de las referencias de Key Vault de la Function.
4) Renueva la otra clave, que invalida la anterior.
Alterna -TargetKey en cada rotación: el despliegue inicial usa primary, la primera rotación usa secondary.
Requiere la extensión azure-iot de la CLI (az extension add --name azure-iot).
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateSet('primary', 'secondary')][string] $TargetKey = 'secondary',
    [string] $ResourceGroup = 'rg-dsa-demo'
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib/DsaInfra.psm1') -Force

$iotHub = Invoke-DsaAz iot hub list --resource-group $ResourceGroup --query '[0].name' --output tsv
$vault = Invoke-DsaAz keyvault list --resource-group $ResourceGroup --query '[0].name' --output tsv
$appId = Invoke-DsaAz functionapp list --resource-group $ResourceGroup --query '[0].id' --output tsv
if (-not ($iotHub -and $vault -and $appId)) { throw "Faltan recursos en $ResourceGroup (IoT Hub, Key Vault o Function App)." }

Invoke-DsaKeyRotation -ResourceGroup $ResourceGroup -IotHubName $iotHub -KeyVaultName $vault -FunctionAppId $appId `
    -SecretTemplateFile (Join-Path $PSScriptRoot 'modules/iothub-secret.bicep') -TargetKey $TargetKey
Write-Host "Rotación terminada. Próxima rotación: -TargetKey $(if ($TargetKey -eq 'primary') { 'secondary' } else { 'primary' })."
Write-Host 'Si vuelves a ejecutar infra/deploy, el secreto vuelve a usar primary; tras el paso 4 esa clave es nueva y válida.'
