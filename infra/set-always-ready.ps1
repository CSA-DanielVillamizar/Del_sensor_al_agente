#Requires -Version 7.0
<#
.SYNOPSIS
Cambia las instancias always ready de function:ingest_event según el escenario, sin redesplegar (T-020, ADR-005 §2).

.EXAMPLE
./infra/set-always-ready.ps1 -Scenario ensayo   # 1 instancia
./infra/set-always-ready.ps1 -Scenario reposo   # 0 instancias (vuelve al costo de centavos)
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][ValidateSet('reposo', 'ensayo', 'sesion')][string] $Scenario,
    # Por defecto, DSA_RESOURCE_GROUP del entorno (el runbook carga .env en la sesión).
    [string] $ResourceGroup = $env:DSA_RESOURCE_GROUP,
    [string] $FunctionAppName
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib/DsaInfra.psm1') -Force

if (-not $ResourceGroup) { throw 'Falta el grupo de recursos: usa -ResourceGroup o define DSA_RESOURCE_GROUP.' }
if (-not $FunctionAppName) {
    $FunctionAppName = Invoke-DsaAz functionapp list --resource-group $ResourceGroup --query '[0].name' --output tsv
    if (-not $FunctionAppName) { throw "No hay Function App en $ResourceGroup." }
}
$count = Set-DsaAlwaysReady -ResourceGroup $ResourceGroup -FunctionAppName $FunctionAppName -Scenario $Scenario
Write-Host "$FunctionAppName -> escenario $Scenario, always ready = $count. Costo de línea base: ver docs/costos.md."
