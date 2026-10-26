#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# Pruebas de las funciones de infra/lib/DsaInfra.psm1 (T-019, T-020). No llaman a Azure:
# Invoke-DsaAz se simula con Mock.

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
    Import-Module (Join-Path $script:RepoRoot 'infra/lib/DsaInfra.psm1') -Force
}

Describe 'Get-DsaRequiredProviders' {
    It 'incluye los siete proveedores de la plantilla' {
        $p = Get-DsaRequiredProviders
        $p | Should -HaveCount 7
        foreach ($ns in 'Microsoft.Devices', 'Microsoft.Web', 'Microsoft.KeyVault', 'Microsoft.Storage',
            'Microsoft.Insights', 'Microsoft.OperationalInsights', 'Microsoft.ManagedIdentity') {
            $p | Should -Contain $ns
        }
    }
}

Describe 'Get-DsaProvidersToRegister' {
    It 'devuelve solo los que no están Registered' {
        $state = @{}
        Get-DsaRequiredProviders | ForEach-Object { $state[$_] = 'Registered' }
        $state['Microsoft.Devices'] = 'NotRegistered'
        $state['Microsoft.Web'] = 'Registering'
        $r = Get-DsaProvidersToRegister -State $state
        $r | Should -HaveCount 2
        $r | Should -Contain 'Microsoft.Devices'
        $r | Should -Contain 'Microsoft.Web'
    }
    It 'trata como pendiente un proveedor sin estado' {
        Get-DsaProvidersToRegister -State @{} | Should -HaveCount 7
    }
}

Describe 'Test-DsaGuid y Test-DsaResourceGroupName' {
    It 'acepta un GUID y rechaza vacío, cero y texto' {
        Test-DsaGuid -Value ([guid]::NewGuid().ToString()) | Should -BeTrue
        Test-DsaGuid -Value '' | Should -BeFalse
        Test-DsaGuid -Value ([guid]::Empty.ToString()) | Should -BeFalse
        Test-DsaGuid -Value '<objectId>' | Should -BeFalse
    }
    It 'valida nombres de grupo de recursos' {
        Test-DsaResourceGroupName -Name 'rg-dsa-demo' | Should -BeTrue
        Test-DsaResourceGroupName -Name 'rg.' | Should -BeFalse
        Test-DsaResourceGroupName -Name 'rg dsa' | Should -BeFalse
        Test-DsaResourceGroupName -Name '' | Should -BeFalse
        Test-DsaResourceGroupName -Name ('a' * 91) | Should -BeFalse
    }
}

Describe 'Get-DsaAlwaysReadyCount' {
    It 'reposo = 0, ensayo = 1, sesion = 1 (ADR-005 §2)' {
        Get-DsaAlwaysReadyCount -Scenario reposo | Should -Be 0
        Get-DsaAlwaysReadyCount -Scenario ensayo | Should -Be 1
        Get-DsaAlwaysReadyCount -Scenario sesion | Should -Be 1
    }
    It 'rechaza un escenario desconocido' {
        { Get-DsaAlwaysReadyCount -Scenario olvido } | Should -Throw
    }
}

Describe 'New-DsaDeploymentArguments' {
    It 'arma create con los parámetros no vacíos y salida json' {
        $a = New-DsaDeploymentArguments -Mode create -ResourceGroup 'rg-x' -TemplateFile 'main.bicep' `
            -ParametersFile 'main.bicepparam' -Parameters ([ordered]@{ iotHubSku = 'B1'; graphSiteId = ''; alwaysReadyCount = 0 })
        ($a -join ' ') | Should -Match '^deployment group create --resource-group rg-x'
        $a | Should -Contain 'iotHubSku=B1'
        $a | Should -Contain 'alwaysReadyCount=0'
        ($a -join ' ') | Should -Not -Match 'graphSiteId'
        $a[-1] | Should -Be 'json'
    }
    It 'what-if no pide salida json' {
        $a = New-DsaDeploymentArguments -Mode what-if -ResourceGroup 'rg-x' -TemplateFile 't' -ParametersFile 'p'
        $a[2] | Should -Be 'what-if'
        $a | Should -Not -Contain 'json'
    }
}

Describe 'Format-DsaAdminCommands' {
    BeforeAll {
        $script:text = Format-DsaAdminCommands -ClientId '<clientId>' -ObjectId '<objectId>'
    }
    It 'usa el object ID en el comando 1 y el client ID en el comando 2' {
        $script:text | Should -Match "New-MgServicePrincipalAppRoleAssignment -ServicePrincipalId '<objectId>' -PrincipalId '<objectId>'"
        $script:text | Should -Match "application = @\{ id = '<clientId>'"
    }
    It 'asigna Sites.Selected y solo el rol write' {
        $script:text | Should -Match "-AppRoleId '883ea226-0bf2-4a8f-9f9d-92c9162a727d'"
        $script:text | Should -Match "roles = @\('write'\)"
        $script:text | Should -Not -Match 'Sites\.ReadWrite\.All|FullControl.*grantedTo'
    }
    It 'coincide con docs/admin-sites-selected.md (una sola fuente de los comandos)' {
        $doc = Get-Content -Raw (Join-Path $script:RepoRoot 'docs/admin-sites-selected.md')
        foreach ($line in ($script:text -split "`r?`n" | Where-Object { $_ -and -not $_.StartsWith('#') })) {
            $doc.Contains($line) | Should -BeTrue -Because "la guía debe contener: $line"
        }
    }
}

Describe 'Copy-DsaContracts y Get-DsaPackageFiles' {
    BeforeEach {
        $repo = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        foreach ($f in Get-DsaContractFiles) {
            $p = Join-Path $repo $f
            New-Item -ItemType Directory -Path (Split-Path $p -Parent) -Force | Out-Null
            Set-Content -Path $p -Value '{}'
        }
        New-Item -ItemType Directory -Path (Join-Path $repo 'function/__pycache__') -Force | Out-Null
        Set-Content -Path (Join-Path $repo 'function/function_app.py') -Value '# app'
        Set-Content -Path (Join-Path $repo 'function/__pycache__/x.pyc') -Value 'x'
        Set-Content -Path (Join-Path $repo 'function/local.settings.json') -Value '{}'
    }
    It 'copia los tres contratos a function/_contracts' {
        $copied = Copy-DsaContracts -RepoRoot $repo
        $copied | Should -HaveCount 3
        Test-Path (Join-Path $repo 'function/_contracts/evento-dispositivo.schema.json') | Should -BeTrue
        Test-Path (Join-Path $repo 'function/_contracts/zonas.json') | Should -BeTrue
        Test-Path (Join-Path $repo 'function/_contracts/columnas.json') | Should -BeTrue
    }
    It 'falla si falta un contrato' {
        Remove-Item (Join-Path $repo 'sharepoint/columnas.json')
        { Copy-DsaContracts -RepoRoot $repo } | Should -Throw '*columnas.json*'
    }
    It 'excluye cachés y local.settings.json del paquete' {
        Copy-DsaContracts -RepoRoot $repo | Out-Null
        $files = Get-DsaPackageFiles -FunctionDir (Join-Path $repo 'function')
        $files | Should -Contain 'function_app.py'
        ($files -join ';') | Should -Match '_contracts'
        ($files -join ';') | Should -Not -Match '__pycache__|local\.settings'
    }
    It 'genera un zip con los contratos' {
        $zip = Join-Path $TestDrive 'pkg.zip'
        New-DsaFunctionPackage -RepoRoot $repo -OutputZip $zip | Should -Be $zip
        $entries = [IO.Compression.ZipFile]::OpenRead($zip)
        try { ($entries.Entries.FullName -join ';') | Should -Match '_contracts[\\/]zonas\.json' }
        finally { $entries.Dispose() }
    }
}

Describe 'Always ready con az simulado' {
    It 'ensayo llama a always-ready set con function:ingest_event=1' {
        Mock -ModuleName DsaInfra Invoke-DsaAz { }
        Set-DsaAlwaysReady -ResourceGroup 'rg-x' -FunctionAppName 'func-x' -Scenario ensayo | Should -Be 1
        Should -Invoke -ModuleName DsaInfra Invoke-DsaAz -Times 1 -ParameterFilter {
            ($Arguments -join ' ') -match 'always-ready set .*--settings function:ingest_event=1'
        }
    }
    It 'reposo elimina la designación' {
        Mock -ModuleName DsaInfra Invoke-DsaAz { }
        Set-DsaAlwaysReady -ResourceGroup 'rg-x' -FunctionAppName 'func-x' -Scenario reposo | Should -Be 0
        Should -Invoke -ModuleName DsaInfra Invoke-DsaAz -Times 1 -ParameterFilter {
            ($Arguments -join ' ') -match 'always-ready delete .*--setting-names function:ingest_event'
        }
    }
    It '-WhatIf no llama a az' {
        Mock -ModuleName DsaInfra Invoke-DsaAz { }
        Set-DsaAlwaysReady -ResourceGroup 'rg-x' -FunctionAppName 'func-x' -Scenario sesion -WhatIf | Out-Null
        Should -Invoke -ModuleName DsaInfra Invoke-DsaAz -Times 0
    }
}

Describe 'Rotación de la clave de func-reader' {
    It 'el plan renueva primero la clave destino y al final la otra' {
        $plan = Get-DsaRotationPlan -TargetKey secondary
        $plan.Action | Should -Be @('renew-key', 'write-secret', 'refresh-references', 'renew-key')
        $plan[0].Key | Should -Be 'secondary'
        $plan[1].Key | Should -Be 'secondary'
        $plan[3].Key | Should -Be 'primary'
    }
    It 'renew-key descarta la salida (no imprime claves)' {
        $a = Get-DsaRenewKeyCommand -ResourceGroup 'rg-x' -IotHubName 'iot-x' -Key primary
        ($a -join ' ') | Should -Match 'policy renew-key .*--name func-reader --renew-key primary --output none$'
    }
    It 'el secreto se reescribe con la plantilla, sin valores de clave en la línea de comandos' {
        $a = Get-DsaWriteSecretCommand -ResourceGroup 'rg-x' -IotHubName 'iot-x' -KeyVaultName 'kv-x' -Key secondary -TemplateFile 'iothub-secret.bicep'
        $a | Should -Contain 'keySlot=secondary'
        ($a -join ' ') | Should -Not -Match 'SharedAccessKey|secret set'
    }
    It 'la recarga usa el endpoint documentado' {
        $a = Get-DsaRefreshReferencesCommand -FunctionAppId '/subscriptions/s/resourceGroups/rg-x/providers/Microsoft.Web/sites/func-x'
        $a | Should -Contain 'https://management.azure.com/subscriptions/s/resourceGroups/rg-x/providers/Microsoft.Web/sites/func-x/config/configreferences/appsettings/refresh?api-version=2022-03-01'
    }
    It 'ejecuta los cuatro pasos en orden con az simulado' {
        $script:calls = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName DsaInfra Invoke-DsaAz { $script:calls.Add(($Arguments -join ' ')) }
        Mock -ModuleName DsaInfra Write-Host { }
        Invoke-DsaKeyRotation -ResourceGroup 'rg-x' -IotHubName 'iot-x' -KeyVaultName 'kv-x' `
            -FunctionAppId '/subscriptions/s/resourceGroups/rg-x/providers/Microsoft.Web/sites/func-x' `
            -SecretTemplateFile 'iothub-secret.bicep' -TargetKey secondary
        $script:calls | Should -HaveCount 4
        $script:calls[0] | Should -Match 'renew-key secondary'
        $script:calls[1] | Should -Match 'deployment group create .*keySlot=secondary'
        $script:calls[2] | Should -Match '^rest --method post'
        $script:calls[3] | Should -Match 'renew-key primary'
    }
}
