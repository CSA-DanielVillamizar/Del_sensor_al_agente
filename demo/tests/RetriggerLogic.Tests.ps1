#Requires -Version 7.0
# T-048 (HU-14, ADR-004 §2): pruebas de la lógica pura de demo/retrigger.ps1. Sin Graph ni red.

BeforeAll {
    $script:Root = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    Import-Module (Join-Path $script:Root 'demo' 'ResetLogic.psm1') -Force
    $script:Id = '3f2b8a4e-6c1d-4e9a-9f7b-2d5c8e1a0b37'
}

Describe 'Test-DsaEventId' {
    It 'acepta el UUID del esquema y rechaza lo demás' {
        Test-DsaEventId $script:Id | Should -BeTrue
        Test-DsaEventId $script:Id.ToUpperInvariant() | Should -BeFalse
        Test-DsaEventId "x' or 1 eq 1 or 'a" | Should -BeFalse
        Test-DsaEventId '' | Should -BeFalse
        Test-DsaEventId $null | Should -BeFalse
    }
}

Describe 'Get-DsaItemByEventIdUri' {
    It 'filtra por la columna indexada EventId y trae solo los campos necesarios' {
        $uri = Get-DsaItemByEventIdUri -SiteId 's' -ListId 'l' -EventId $script:Id
        $uri | Should -BeLike 'v1.0/sites/s/lists/l/items?$filter=*'
        [uri]::UnescapeDataString($uri) | Should -BeLike "*fields/EventId eq '$($script:Id)'*"
        $uri | Should -BeLike '*fields($select=EventId,Estado,EsPrueba)*'
    }
    It 'no deja inyectar nada en el filtro' {
        { Get-DsaItemByEventIdUri -SiteId 's' -ListId 'l' -EventId "x' or 1 eq 1" } | Should -Throw
    }
}

Describe 'Get-DsaRetriggerDecision' {
    It 'llama al flujo solo si el elemento sigue en Nuevo' {
        (Get-DsaRetriggerDecision -Items @(@{ id = '1'; fields = @{ Estado = 'Nuevo' } })).Action | Should -Be 'Trigger'
    }
    It 'no llama si ya avanzó' {
        foreach ($estado in 'Pendiente de decisión', 'Atendido', 'Escalado', 'Falsa alarma', 'Sin respuesta', 'nuevo') {
            $decision = Get-DsaRetriggerDecision -Items @(@{ id = '1'; fields = @{ Estado = $estado } })
            $decision.Action | Should -Be 'Skip' -Because $estado
            $decision.Estado | Should -Be $estado
        }
    }
    It 'informa si no existe o si hay más de uno' {
        (Get-DsaRetriggerDecision -Items @()).Action | Should -Be 'NotFound'
        (Get-DsaRetriggerDecision -Items $null).Action | Should -Be 'NotFound'
        $two = @(@{ id = '1'; fields = @{ Estado = 'Nuevo' } }, @{ id = '2'; fields = @{ Estado = 'Nuevo' } })
        (Get-DsaRetriggerDecision -Items $two).Action | Should -Be 'Ambiguous'
    }
}

Describe 'Llamada al flujo' {
    It 'exige una URL https absoluta' {
        Test-DsaFlowUrl 'https://example.invalid/workflows/abc/triggers/manual/paths/invoke' | Should -BeTrue
        Test-DsaFlowUrl 'http://example.invalid/x' | Should -BeFalse
        Test-DsaFlowUrl 'example.invalid/x' | Should -BeFalse
        Test-DsaFlowUrl '' | Should -BeFalse
    }
    It 'rechaza una URL con firma SAS (sig=)' {
        Test-DsaFlowUrl 'https://example.invalid/workflows/abc?api-version=1&SIG=falsa' | Should -BeFalse
    }
    It 'envía solo el eventId (§4.5) con el token de usuario como Bearer' {
        $request = New-DsaFlowRequest -FlowUrl 'https://example.invalid/invoke' -EventId $script:Id -AccessToken 'token-falso'
        $request.Method | Should -Be 'Post'
        $request.Uri | Should -Be 'https://example.invalid/invoke'
        $request.ContentType | Should -Be 'application/json'
        $request.Headers.Authorization | Should -Be 'Bearer token-falso'
        $request.Body | Should -Be "{`"eventId`":`"$($script:Id)`"}"
        @(($request.Body | ConvertFrom-Json).PSObject.Properties.Name) | Should -Be @('eventId')
    }
    It 'rechaza un EventId o una URL inválidos antes de llamar' {
        { New-DsaFlowRequest -FlowUrl 'https://example.invalid/invoke' -EventId 'abc' -AccessToken 't' } | Should -Throw
        { New-DsaFlowRequest -FlowUrl 'http://example.invalid/invoke' -EventId $script:Id -AccessToken 't' } | Should -Throw
    }
    It 'muestra solo el host de la URL del flujo' {
        Get-DsaSafeHost 'https://prod-00.example.invalid:443/workflows/abc?api-version=1&sig=secreto' | Should -Be 'prod-00.example.invalid'
        Get-DsaSafeHost 'no es url' | Should -Be '(URL no válida)'
    }
}

Describe 'retrigger.ps1' {
    BeforeAll { $script:Text = Get-Content (Join-Path $script:Root 'demo' 'retrigger.ps1') -Raw }
    It 'no tiene errores de sintaxis' {
        $errors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $script:Root 'demo' 'retrigger.ps1'), [ref]$null, [ref]$errors)
        $errors.Count | Should -Be 0
    }
    It 'pide el token con la audiencia exacta del flujo y lee la URL de DSA_FLOW_URL' {
        $script:Text | Should -Match "\`$FlowResource = 'https://service.flow.microsoft.com/'"
        $script:Text | Should -Match 'az account get-access-token --resource \$FlowResource'
        $script:Text | Should -Match "'DSA_FLOW_URL'"
        $script:Text | Should -Match "\`$RequiredScopes = @\('Sites.Read.All'\)"
    }
    It 'no escribe el token ni la URL del flujo en pantalla' {
        $script:Text | Should -Not -Match 'Write-(Host|Output|DsaLine)[^\r\n]*\$token'
        $script:Text | Should -Not -Match 'Write-(Host|Output|DsaLine)[^\r\n]*\$flowUrl\b(?!\))'
    }
}
