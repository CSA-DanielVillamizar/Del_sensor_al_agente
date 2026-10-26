#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
    T-040 HU-08 (CA-08.6) y HU-05 (CA-05.5): pruebas de la lógica pura de demo/measure.ps1 y demo/inject.ps1.
    Sin Graph, sin red y sin reloj real. Ejecutar desde la raíz:  pwsh -NoProfile -Command "Invoke-Pester demo/tests"
#>

BeforeAll {
    $script:Root = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    Import-Module (Join-Path $Root 'demo' 'DemoLogic.psm1') -Force
    $script:Zones = Get-Content (Join-Path $Root 'data' 'zonas.json') -Raw -Encoding utf8 | ConvertFrom-Json
    $script:Utc = { param([string]$s) [DateTimeOffset]::Parse($s, [cultureinfo]::InvariantCulture).UtcDateTime }

    function New-Item2([string]$EventId, [string]$Created, [string]$Recibido = $null) {
        [pscustomobject]@{ EventId = $EventId; CreatedUtc = (& $Utc $Created); RecibidoUtc = $(if ($Recibido) { & $Utc $Recibido } else { $null }) }
    }
    function New-Msg([string]$Created, [string]$Body = '', [object[]]$Attachments = @()) {
        @{ createdDateTime = $Created; body = @{ content = $Body }; attachments = $Attachments }
    }
}

Describe 'Get-SeveridadInicial (§5.0)' {
    It 'toma el mayor entre rawSeverity y baseSeverity' {
        Get-SeveridadInicial -RawSeverity 'Baja' -BaseSeverity 'Alta' | Should -Be 'Alta'
        Get-SeveridadInicial -RawSeverity 'Crítica' -BaseSeverity 'Media' | Should -Be 'Crítica'
        Get-SeveridadInicial -RawSeverity 'Media' -BaseSeverity 'Media' | Should -Be 'Media'
    }
    It 'rechaza un valor fuera de la escala' {
        { Get-SeveridadInicial -RawSeverity 'Urgente' -BaseSeverity 'Media' } | Should -Throw '*escala*'
    }
}

Describe 'Get-ZoneEntry' {
    It 'devuelve la zona del catálogo ficticio' {
        (Get-ZoneEntry -Zones $Zones -Zone 'Z-03').zoneName | Should -Be 'Bodega norte'
    }
    It 'una zona fuera del catálogo es un error (ADR-004)' {
        { Get-ZoneEntry -Zones $Zones -Zone 'Z-99' } | Should -Throw '*catálogo*'
    }
}

Describe 'Horario diurno (06:00 ≤ hora < 18:00 en America/Bogota)' {
    It 'convierte UTC a Bogotá con UTC−5 fijo' {
        (ConvertTo-BogotaTime -Utc (& $Utc '2026-11-04T19:32:05Z')).ToString('HH:mm') | Should -Be '14:32'
    }
    It 'las 06:00 están dentro' { Test-Daytime -Utc (& $Utc '2026-11-04T11:00:00Z') | Should -BeTrue }
    It 'las 05:59 están fuera' { Test-Daytime -Utc (& $Utc '2026-11-04T10:59:00Z') | Should -BeFalse }
    It 'las 17:59 están dentro' { Test-Daytime -Utc (& $Utc '2026-11-04T22:59:00Z') | Should -BeTrue }
    It 'las 18:00 están fuera' { Test-Daytime -Utc (& $Utc '2026-11-04T23:00:00Z') | Should -BeFalse }
}

Describe 'ConvertTo-UtcDateTime' {
    It 'acepta texto ISO con Z' {
        $d = ConvertTo-UtcDateTime '2026-11-04T19:32:05Z'
        $d.Kind | Should -Be 'Utc'
        $d.Hour | Should -Be 19
    }
    It 'acepta texto con desfase y lo pasa a UTC' {
        (ConvertTo-UtcDateTime '2026-11-04T14:32:05-05:00').Hour | Should -Be 19
    }
    It 'trata un DateTime sin zona como UTC' {
        $d = ConvertTo-UtcDateTime ([datetime]::new(2026, 11, 4, 19, 32, 5, [DateTimeKind]::Unspecified))
        $d.Kind | Should -Be 'Utc'
        $d.Hour | Should -Be 19
    }
    It 'devuelve $null para vacío' { ConvertTo-UtcDateTime $null | Should -BeNullOrEmpty }
}

Describe 'Get-FunctionColumnNames' {
    It 'lee las columnas que escribe la Function desde columnas.json' {
        $names = Get-FunctionColumnNames -ContractPath (Join-Path $Root 'sharepoint' 'columnas.json')
        $names | Should -Contain 'EventId'
        $names | Should -Contain 'Estado'
        $names | Should -Not -Contain 'Decision'
    }
    It 'sin archivo usa los nombres del plan §4.3' {
        $names = Get-FunctionColumnNames -ContractPath (Join-Path $TestDrive 'no-existe.json')
        $names.Count | Should -Be 15
        $names | Should -Contain 'RecibidoUtc'
    }
    It 'columnas.json y la lista del plan coinciden' {
        $fromFile = Get-FunctionColumnNames -ContractPath (Join-Path $Root 'sharepoint' 'columnas.json')
        $fromPlan = Get-FunctionColumnNames -ContractPath (Join-Path $TestDrive 'no-existe.json')
        Compare-Object $fromFile $fromPlan | Should -BeNullOrEmpty
    }
}

Describe 'New-IncidentFields' {
    BeforeAll {
        $script:Names = Get-FunctionColumnNames -ContractPath (Join-Path $Root 'sharepoint' 'columnas.json')
        $script:Base = @{
            EventId        = '3f2b8a4e-6c1d-4e9a-9f7b-2d5c8e1a0b37'
            DeviceId       = 'DEV-INJECT-01'
            Type           = 'puerta_forzada'
            Zone           = 'Z-03'
            RawSeverity    = 'Baja'
            Zones          = $Zones
            FechaEventoUtc = (& $Utc '2026-11-04T19:32:05Z')
            RecibidoUtc    = (& $Utc '2026-11-04T19:32:06Z')
            Repeticiones   = 1
            ColumnNames    = $Names
        }
    }
    It 'arma exactamente las columnas de la Function' {
        $f = New-IncidentFields @Base
        Compare-Object @($f.Keys) $Names | Should -BeNullOrEmpty
    }
    It 'enriquece con el catálogo y calcula SeveridadInicial' {
        $f = New-IncidentFields @Base
        $f.NombreZona | Should -Be 'Bodega norte'
        $f.CamaraId | Should -Be 'CAM-03'
        $f.Sitio | Should -Be 'Sede Demo Centro'
        $f.SeveridadRaw | Should -Be 'Baja'
        $f.SeveridadInicial | Should -Be 'Media'
        $f.Title | Should -Be 'puerta_forzada · Z-03'
        $f.Estado | Should -Be 'Nuevo'
        $f.EsPrueba | Should -BeFalse
    }
    It 'escribe fechas ISO 8601 en UTC con Z' {
        $f = New-IncidentFields @Base
        $f.FechaEventoUtc | Should -Be '2026-11-04T19:32:05Z'
        $f.RecibidoUtc | Should -Be '2026-11-04T19:32:06Z'
    }
    It 'respeta Repeticiones y EsPrueba' {
        $f = New-IncidentFields @Base -Repeticiones 20 -EsPrueba
        $f.Repeticiones | Should -Be 20
        $f.EsPrueba | Should -BeTrue
    }
    It 'rechaza un tipo desconocido' {
        { New-IncidentFields @Base -Type 'incendio' } | Should -Throw '*tipo*'
    }
    It 'rechaza un deviceId con texto libre' {
        { New-IncidentFields @Base -DeviceId 'Nombre de una persona' } | Should -Throw '*DeviceId*'
    }
    It 'rechaza Repeticiones menor que 1' {
        { New-IncidentFields @Base -Repeticiones 0 } | Should -Throw
    }
    It 'rechaza un evento posterior a la recepción' {
        { New-IncidentFields @Base -FechaEventoUtc (& $Utc '2026-11-04T20:00:00Z') } | Should -Throw '*posterior*'
    }
    It 'falla si el contrato pide una columna que no sabe llenar' {
        { New-IncidentFields @Base -ColumnNames ($Names + 'ColumnaNueva') } | Should -Throw '*ColumnaNueva*'
    }
    It 'el cuerpo de Graph lleva los campos bajo fields' {
        $body = New-IncidentFields @Base | ConvertTo-GraphItemBody | ConvertFrom-Json -AsHashtable
        $body.fields.EventId | Should -Be '3f2b8a4e-6c1d-4e9a-9f7b-2d5c8e1a0b37'
    }
}

Describe 'Llamada al flujo DisparoAgente' {
    It 'exige https' {
        Test-FlowUrl 'https://example.invalid/workflows/x' | Should -BeTrue
        Test-FlowUrl 'http://example.invalid/workflows/x' | Should -BeFalse
        Test-FlowUrl '' | Should -BeFalse
    }
    It 'rechaza una URL con firma SAS (sig=)' {
        Test-FlowUrl 'https://example.invalid/workflows/x?api-version=1&sig=falsa' | Should -BeFalse
        Test-FlowUrl 'https://example.invalid/workflows/x?api-version=1' | Should -BeTrue
    }
    It 'oculta la ruta y la consulta al mostrar la URL' {
        Get-RedactedUrl 'https://example.invalid/workflows/abc?sig=secreto' | Should -Be 'https://example.invalid/…'
    }
    It 'arma la solicitud con solo el eventId (plan §4.5)' {
        $r = New-FlowRequest -FlowUrl 'https://example.invalid/w' -Token 'tkn' -EventId 'e-1'
        $r.Method | Should -Be 'Post'
        $r.Headers.Authorization | Should -Be 'Bearer tkn'
        ($r.Body | ConvertFrom-Json -AsHashtable).Keys | Should -Be @('eventId')
    }
    It 'comprueba la audiencia del token sin validarlo criptográficamente' {
        $enc = { param($o) [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($o | ConvertTo-Json -Compress))).TrimEnd('=').Replace('+', '-').Replace('/', '_') }
        $good = "$(& $enc @{alg='none'}).$(& $enc @{aud='https://service.flow.microsoft.com/'}).x"
        $bad = "$(& $enc @{alg='none'}).$(& $enc @{aud='https://api.powerplatform.com'}).x"
        Get-TokenAudience $good | Should -Be 'https://service.flow.microsoft.com/'
        Test-FlowTokenAudience $good | Should -BeTrue
        Test-FlowTokenAudience $bad | Should -BeFalse
    }
}

Describe 'Find-EventReference' {
    It 'encuentra Ref. {eventId} en el cuerpo' {
        Find-EventReference (New-Msg '2026-11-04T19:32:20Z' '<p>Ref. 3f2b8a4e-6c1d-4e9a-9f7b-2d5c8e1a0b37</p>') |
            Should -Be '3f2b8a4e-6c1d-4e9a-9f7b-2d5c8e1a0b37'
    }
    It 'encuentra la referencia dentro de la tarjeta adjunta' {
        $card = '{"type":"AdaptiveCard","body":[{"type":"TextBlock","text":"Ref. 7c1e9d2a-4b6f-4f0e-8a3d-5e2b9c7a1f04"}]}'
        $msg = New-Msg '2026-11-04T19:32:20Z' '<attachment id="1"></attachment>' @(@{ contentType = 'application/vnd.microsoft.card.adaptive'; content = $card })
        Find-EventReference $msg | Should -Be '7c1e9d2a-4b6f-4f0e-8a3d-5e2b9c7a1f04'
    }
    It 'devuelve $null si no hay referencia' {
        Find-EventReference (New-Msg '2026-11-04T19:32:20Z' 'hola') | Should -BeNullOrEmpty
    }
}

Describe 'Join-IncidentMessages' {
    It 'une por eventId, toma el primer mensaje y calcula tramo 1, tramo 2 y total' {
        $items = @(New-Item2 'aaaaaaaa-0000-4000-8000-000000000001' '2026-11-04T19:32:10Z' '2026-11-04T19:32:05Z')
        $msgs = @(
            New-Msg '2026-11-04T19:50:00Z' 'Sin respuesta. Ref. aaaaaaaa-0000-4000-8000-000000000001'
            New-Msg '2026-11-04T19:32:22Z' 'Ref. aaaaaaaa-0000-4000-8000-000000000001'
        )
        $r = Join-IncidentMessages -Items $items -Messages $msgs -Now (& $Utc '2026-11-04T20:00:00Z')
        $r.Tramo1 | Should -Be 5
        $r.Tramo2 | Should -Be 12
        $r.Total | Should -Be 17
        $r.Vencido | Should -BeFalse
    }
    It 'sin tarjeta y pasado el tiempo de espera queda vencido' {
        $items = @(New-Item2 'aaaaaaaa-0000-4000-8000-000000000002' '2026-11-04T19:32:10Z' '2026-11-04T19:32:05Z')
        $r = Join-IncidentMessages -Items $items -Messages @() -Now (& $Utc '2026-11-04T19:34:00Z') -TimeoutSeconds 60
        $r.Tramo2 | Should -BeNullOrEmpty
        $r.Vencido | Should -BeTrue
    }
    It 'sin tarjeta y dentro del tiempo de espera queda pendiente' {
        $items = @(New-Item2 'aaaaaaaa-0000-4000-8000-000000000003' '2026-11-04T19:32:10Z')
        $r = Join-IncidentMessages -Items $items -Messages @() -Now (& $Utc '2026-11-04T19:32:30Z') -TimeoutSeconds 60
        $r.Vencido | Should -BeFalse
        $r.Total | Should -BeNullOrEmpty
    }
    It 'sin RecibidoUtc no calcula tramo 1 ni total' {
        $items = @(New-Item2 'aaaaaaaa-0000-4000-8000-000000000004' '2026-11-04T19:32:10Z')
        $msgs = @(New-Msg '2026-11-04T19:32:20Z' 'Ref. aaaaaaaa-0000-4000-8000-000000000004')
        $r = Join-IncidentMessages -Items $items -Messages $msgs -Now (& $Utc '2026-11-04T20:00:00Z')
        $r.Tramo2 | Should -Be 10
        $r.Tramo1 | Should -BeNullOrEmpty
        $r.Total | Should -BeNullOrEmpty
    }
}

Describe 'Select-LastItems' {
    It 'devuelve los N más recientes por fecha de creación' {
        $items = 1..5 | ForEach-Object { New-Item2 "e-$_" ('2026-11-04T19:3{0}:00Z' -f $_) }
        (Select-LastItems -Items $items -Last 2).EventId | Should -Be @('e-4', 'e-5')
    }
}

Describe 'Get-LatencySummary' {
    BeforeAll {
        function New-Row($t2, $total, [bool]$vencido = $false) {
            [pscustomobject]@{ EventId = 'x'; Tramo1 = $null; Tramo2 = $t2; Total = $total; Vencido = $vencido }
        }
    }
    It 'cumple con p90 de tramo 2 ≤ 20 s y total ≤ 30 s, máximo ≤ 60 s' {
        $rows = 1..10 | ForEach-Object { New-Row (5 + $_) (10 + $_) }
        $s = Get-LatencySummary -Rows $rows
        $s.N | Should -Be 10
        $s.Tramo2P90 | Should -Be 14
        $s.TotalP90 | Should -Be 19
        $s.Veredicto | Should -Be 'Cumple'
    }
    It 'un incidente sin tarjeta cuenta como +Infinito y no cumple' {
        $rows = @(1..9 | ForEach-Object { New-Row 8 12 }) + @(New-Row $null $null $true)
        $s = Get-LatencySummary -Rows $rows
        $s.SinTarjeta | Should -Be 1
        [double]::IsInfinity($s.Tramo2Max) | Should -BeTrue
        $s.Veredicto | Should -Be 'No cumple'
    }
    It 'con pendientes el veredicto es Pendiente' {
        $rows = @(New-Row 8 12) + @(New-Row $null $null $false)
        (Get-LatencySummary -Rows $rows).Veredicto | Should -Be 'Pendiente'
    }
    It 'un total mayor de 60 s no cumple aunque el p90 cumpla' {
        $rows = @(1..9 | ForEach-Object { New-Row 8 12 }) + @(New-Row 15 61)
        (Get-LatencySummary -Rows $rows).Veredicto | Should -Be 'No cumple'
    }
    It 'menos de 10 ensayos se informa como insuficiente' {
        $rows = 1..3 | ForEach-Object { New-Row 8 12 }
        (Get-LatencySummary -Rows $rows).Veredicto | Should -Be 'Cumple (muestra < 10)'
    }
    It 'el informe Markdown muestra la tabla' {
        $rows = 1..10 | ForEach-Object { New-Row 8 12 }
        $md = ConvertTo-LatencyMarkdown -Summary (Get-LatencySummary -Rows $rows) -GeneratedUtc (& $Utc '2026-11-04T20:00:00Z')
        ($md -join "`n") | Should -Match '\| Tramo 2 \|'
    }
}
