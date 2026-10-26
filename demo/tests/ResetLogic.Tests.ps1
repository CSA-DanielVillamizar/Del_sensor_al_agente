#Requires -Version 7.0
# T-046 (HU-14 CA-14.2): pruebas de la lógica pura de demo/reset.ps1. Sin Graph ni Azure.

BeforeAll {
    $script:Root = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    Import-Module (Join-Path $script:Root 'demo' 'ResetLogic.psm1') -Force

    function New-Item365([string] $Id, [object] $EsPrueba, [string] $Estado = 'Nuevo') {
        @{ id = $Id; fields = @{ EventId = "evt-$Id"; Estado = $Estado; EsPrueba = $EsPrueba } }
    }
}

Describe 'ConvertTo-DsaBoolean' {
    It 'interpreta booleanos de Graph y textos de exportación' {
        ConvertTo-DsaBoolean $true | Should -BeTrue
        ConvertTo-DsaBoolean $false | Should -BeFalse
        ConvertTo-DsaBoolean 'Sí' | Should -BeTrue
        ConvertTo-DsaBoolean '1' | Should -BeTrue
        ConvertTo-DsaBoolean 'No' | Should -BeFalse
        ConvertTo-DsaBoolean $null | Should -BeFalse
    }
}

Describe 'Select-DsaResetItems' {
    BeforeAll {
        $script:Items = @(
            (New-Item365 '1' $true 'Pendiente de decisión')
            (New-Item365 '2' $false 'Atendido')
            (New-Item365 '3' $true)
            (New-Item365 '4' $null)
        )
    }
    It 'por defecto elige solo los de EsPrueba = Sí (CA-14.2)' {
        $selected = Select-DsaResetItems -Items $script:Items
        $selected.Id | Should -Be @('1', '3')
        $selected[0].EventId | Should -Be 'evt-1'
        $selected[0].Estado | Should -Be 'Pendiente de decisión'
    }
    It 'con -All elige todos' {
        (Select-DsaResetItems -Items $script:Items -All).Count | Should -Be 4
    }
    It 'una lista vacía no elige nada' {
        (Select-DsaResetItems -Items @()).Count | Should -Be 0
        (Select-DsaResetItems -Items $null).Count | Should -Be 0
    }
}

Describe 'Table Storage' {
    It 'vacía exactamente dedup y ratelimit (ADR-006)' {
        Get-DsaResetTables | Should -Be @('dedup', 'ratelimit')
    }
    It 'escapa la barra vertical de la PartitionKey de dedup y las comillas simples' {
        $uri = Get-DsaTableEntityUri -Account 'stdsaabc123' -Table 'dedup' -PartitionKey 'sim-01|puerta_forzada' -RowKey 'current'
        $uri | Should -Be "https://stdsaabc123.table.core.windows.net/dedup(PartitionKey='sim-01%7Cpuerta_forzada',RowKey='current')"
        $quoted = Get-DsaTableEntityUri -Account 'stdsaabc123' -Table 'dedup' -PartitionKey "o'k" -RowKey 'w|x y'
        $quoted | Should -BeLike "*PartitionKey='o%27%27k'*"
        $quoted | Should -BeLike "*RowKey='w%7Cx%20y'*"
    }
    It 'rechaza nombres de cuenta o tabla inválidos' {
        { Get-DsaTableEntityUri -Account 'Cuenta.Mala' -Table 'dedup' -PartitionKey 'a' -RowKey 'b' } | Should -Throw
        { Get-DsaTableEntityUri -Account 'stdsa' -Table 'de/dup' -PartitionKey 'a' -RowKey 'b' } | Should -Throw
    }
    It 'lee la salida de az storage entity query con y sin marcador' {
        $json = '{"items":[{"PartitionKey":"sim-01|puerta_forzada","RowKey":"current"},{"PartitionKey":"minute","RowKey":"202611041000"}],"nextMarker":{"nextpartitionkey":"1!8!bWludXRl","nextrowkey":"1!4!eA--"}}'
        $page = ConvertFrom-DsaEntityQuery -Json $json
        $page.Entities.Count | Should -Be 2
        $page.Entities[0].PartitionKey | Should -Be 'sim-01|puerta_forzada'
        $page.Marker.nextpartitionkey | Should -Be '1!8!bWludXRl'
        $last = ConvertFrom-DsaEntityQuery -Json '{"items":[],"nextMarker":{}}'
        $last.Entities.Count | Should -Be 0
        $last.Marker | Should -BeNullOrEmpty
        (ConvertFrom-DsaEntityQuery -Json '').Entities.Count | Should -Be 0
        (ConvertFrom-DsaEntityQuery -Json '[{"PartitionKey":"a","RowKey":"b"}]').Entities.Count | Should -Be 1
    }
    It 'consulta con la identidad de Daniel (--auth-mode login) y pasa el marcador' {
        $arguments = Get-DsaEntityQueryArguments -Account 'stdsa' -Table 'dedup' -Marker $null
        ($arguments -join ' ') | Should -BeLike 'storage entity query *--auth-mode login*'
        $arguments | Should -Not -Contain '--marker'
        $arguments | Should -Not -Contain '--account-key'
        $withMarker = Get-DsaEntityQueryArguments -Account 'stdsa' -Table 'dedup' -Marker @{ nextpartitionkey = 'p'; nextrowkey = 'r' }
        $withMarker[-3..-1] | Should -Be @('--marker', 'nextpartitionkey=p', 'nextrowkey=r')
    }
    It 'borra sin condición de ETag y con versión que admite Microsoft Entra ID' {
        $headers = Get-DsaTableDeleteHeaders -AccessToken 'token-falso' -UtcNow ([datetime]::new(2026, 11, 4, 15, 0, 0, [DateTimeKind]::Utc))
        $headers['If-Match'] | Should -Be '*'
        $headers['Authorization'] | Should -Be 'Bearer token-falso'
        $headers['x-ms-version'] | Should -Be '2020-12-06'
        $headers['x-ms-date'] | Should -Be 'Wed, 04 Nov 2026 15:00:00 GMT'
    }
}

Describe 'Format-DsaElapsed' {
    It 'marca en verde dentro de 2 minutos y en amarillo si se pasa' {
        $ok = Format-DsaElapsed -Elapsed ([timespan]::FromSeconds(75.4))
        $ok.WithinTarget | Should -BeTrue
        $ok.Color | Should -Be 'Green'
        $ok.Text | Should -BeLike '01:15.4*02:00*'
        (Format-DsaElapsed -Elapsed ([timespan]::FromSeconds(121))).WithinTarget | Should -BeFalse
    }
}

Describe 'reset.ps1' {
    BeforeAll { $script:Text = Get-Content (Join-Path $script:Root 'demo' 'reset.ps1') -Raw }
    It 'no tiene errores de sintaxis' {
        $errors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $script:Root 'demo' 'reset.ps1'), [ref]$null, [ref]$errors)
        $errors.Count | Should -Be 0
    }
    It 'usa la identidad delegada con Sites.ReadWrite.All y nunca borra de forma definitiva' {
        $script:Text | Should -Match "\`$RequiredScopes = @\('Sites.ReadWrite.All'\)"
        $script:Text | Should -Not -Match 'permanentDelete|deleteObject|recycleBin.*(delete|purge)|Clear-.*RecycleBin'
        $script:Text | Should -Not -Match '--account-key|--connection-string|--sas-token'
    }
}
