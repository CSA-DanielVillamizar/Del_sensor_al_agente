#Requires -Version 7.0
<#
.SYNOPSIS
Elimina el grupo de recursos completo de la demo (CA-04.3, Art. 9).

.DESCRIPTION
Borra el grupo y, salvo -KeepDeletedVault, purga el Key Vault en borrado temporal para poder redesplegar
con el mismo nombre. Al borrar el grupo desaparece id-dsa-func: al redesplegar hay que repetir los dos
comandos del administrador y actualizar el object ID en DisparoAgente (ADR-007).
Pide confirmación salvo -Force. -WhatIf solo muestra qué se borraría.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [string] $ResourceGroup = 'rg-dsa-demo',
    [switch] $KeepDeletedVault,
    [switch] $Force
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib/DsaInfra.psm1') -Force

if (-not (Test-DsaResourceGroupName -Name $ResourceGroup)) { throw "Nombre de grupo de recursos no válido: $ResourceGroup" }
if ((Invoke-DsaAz group exists --name $ResourceGroup) -ne 'true') {
    Write-Host "El grupo $ResourceGroup no existe. Nada que borrar."
    return
}

$vaults = @(Invoke-DsaAz keyvault list --resource-group $ResourceGroup --query '[].name' --output tsv)
$resources = Invoke-DsaAz resource list --resource-group $ResourceGroup --query '[].{tipo:type, nombre:name}' --output table
Write-Host "Recursos en ${ResourceGroup}:"
Write-Host ($resources -join [Environment]::NewLine)

if ($Force -and -not $WhatIfPreference) { $ConfirmPreference = 'None' }
if (-not $PSCmdlet.ShouldProcess($ResourceGroup, 'Eliminar el grupo de recursos completo')) { return }

Invoke-DsaAz group delete --name $ResourceGroup --yes --output none | Out-Null
Write-Host "Grupo $ResourceGroup eliminado."

if (-not $KeepDeletedVault) {
    foreach ($vault in $vaults | Where-Object { $_ }) {
        Write-Host "Purgando el Key Vault $vault (solo guardaba la cadena de func-reader)..."
        Invoke-DsaAz keyvault purge --name $vault --output none | Out-Null
    }
}
