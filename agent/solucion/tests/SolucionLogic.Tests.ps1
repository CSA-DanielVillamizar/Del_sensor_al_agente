#Requires -Version 7.0
# T-056 (HU-13): pruebas de la solución exportada y de su empaquetado.
# Sin red ni tenant: valida que src/ no tenga valores de ningún tenant y que
# pack.ps1 reemplace todos los marcadores con valores ficticios.

BeforeAll {
    $script:Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    Import-Module (Join-Path $script:Root 'SolucionLogic.psm1') -Force
    $script:Src = Join-Path $script:Root 'src'
    $script:Files = Get-ChildItem -LiteralPath $script:Src -Recurse -File
    $script:Fake = @{
        '{{DSA_SITE_URL}}'           = 'https://contoso.sharepoint.com/sites/DSA-Demo-Site'
        '{{DSA_TEAM_ID}}'            = '00000000-0000-0000-0000-000000000001'
        '{{DSA_CHANNEL_ID}}'         = '19:ficticio@thread.tacv2'
        '{{DSA_FLOW_ALLOWED_USERS}}' = '00000000-0000-0000-0000-000000000002'
    }
}

Describe 'Contenido de src/' {
    It 'tiene el manifiesto, el agente y los tres flujos' {
        Test-Path (Join-Path $script:Src 'solution.xml') | Should -BeTrue
        Test-Path (Join-Path $script:Src 'customizations.xml') | Should -BeTrue
        Test-Path (Join-Path $script:Src 'bots' 'dsa_AgentedeOperaciones' 'bot.xml') | Should -BeTrue
        (Get-ChildItem (Join-Path $script:Src 'Workflows') -Filter *.json).Count | Should -Be 3
    }

    It 'no declara dependencias faltantes' {
        $xml = [xml](Get-Content (Join-Path $script:Src 'solution.xml') -Raw)
        @($xml.ImportExportXml.SolutionManifest.MissingDependencies.MissingDependency | Where-Object { $_ }).Count | Should -Be 0
    }

    It 'incluye las tres referencias de conexión' {
        $text = Get-Content (Join-Path $script:Src 'customizations.xml') -Raw
        ([regex]::Matches($text, '<connectionreference ')).Count | Should -Be 3
    }

    It 'no incluye valores actuales de variables de entorno' {
        @($script:Files | Where-Object Name -eq 'environmentvariablevalues.json').Count | Should -Be 0
    }

    It 'no tiene URLs de SharePoint, correos ni identificadores de canal reales' {
        foreach ($file in $script:Files) {
            $text = Get-Content -LiteralPath $file.FullName -Raw
            $text | Should -Not -Match 'https://[a-z0-9-]+\.sharepoint\.com' -Because $file.Name
            $text | Should -Not -Match '[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+\.(com|co|org|net)\b' -Because $file.Name
            $text | Should -Not -Match '19:[A-Za-z0-9_-]+@thread' -Because $file.Name
        }
    }

    It 'solo usa marcadores conocidos' {
        $known = @((Get-DsaSolutionMarkers).Keys)
        foreach ($file in $script:Files) {
            $text = Get-Content -LiteralPath $file.FullName -Raw
            foreach ($m in [regex]::Matches($text, '\{\{DSA_[A-Z_]+\}\}')) {
                $known | Should -Contain $m.Value -Because $file.Name
            }
        }
    }
}

Describe 'Test-DsaSolutionValues' {
    It 'acepta valores con el formato esperado' {
        @(Test-DsaSolutionValues -Values $script:Fake).Count | Should -Be 0
    }

    It 'informa cada valor que falta' {
        $errors = @(Test-DsaSolutionValues -Values @{})
        $errors.Count | Should -Be 4
    }

    It 'rechaza una URL de sitio con barra final' {
        $values = $script:Fake.Clone()
        $values['{{DSA_SITE_URL}}'] = 'https://contoso.sharepoint.com/sites/DSA-Demo-Site/'
        @(Test-DsaSolutionValues -Values $values) | Should -Match 'DSA_SITE_URL'
    }

    It 'rechaza un ObjectId que no es GUID' {
        $values = $script:Fake.Clone()
        $values['{{DSA_FLOW_ALLOWED_USERS}}'] = 'mi-funcion'
        @(Test-DsaSolutionValues -Values $values) | Should -Match 'DSA_FLOW_ALLOWED_USERS'
    }
}

Describe 'New-DsaSolutionPackage' {
    It 'arma un .zip sin marcadores y con los valores dados' {
        $zipPath = Join-Path $TestDrive 'DelSensorAlAgente.zip'
        New-DsaSolutionPackage -SourcePath $script:Src -OutputZip $zipPath -Values $script:Fake | Out-Null
        $dest = Join-Path $TestDrive 'x'
        Expand-Archive -LiteralPath $zipPath -DestinationPath $dest
        (Get-ChildItem -LiteralPath $dest -Recurse -File).Count | Should -Be $script:Files.Count
        Test-Path -LiteralPath (Join-Path $dest '[Content_Types].xml') | Should -BeTrue
        $all = (Get-ChildItem -LiteralPath $dest -Recurse -File | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw }) -join "`n"
        $all | Should -Not -Match '\{\{DSA_'
        $all | Should -Match ([regex]::Escape('https://contoso.sharepoint.com/sites/DSA-Demo-Site'))
        $all | Should -Match ([regex]::Escape('19:ficticio@thread.tacv2'))
    }

    It 'no crea el paquete si faltan valores' {
        $zipPath = Join-Path $TestDrive 'incompleto.zip'
        { New-DsaSolutionPackage -SourcePath $script:Src -OutputZip $zipPath -Values @{} } | Should -Throw
        Test-Path -LiteralPath $zipPath | Should -BeFalse
    }
}
