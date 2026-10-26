#Requires -Version 7.0
# T-047 (HU-14 CA-14.3): pruebas de la lógica pura de demo/preflight.ps1.

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'PreflightLogic.psm1') -Force
}

Describe 'Get-DsaPwshCheck' {
    It 'verde con PowerShell 7' { (Get-DsaPwshCheck -Major 7).Status | Should -Be 'Verde' }
    It 'rojo con PowerShell 5 y da el comando de instalación' {
        $c = Get-DsaPwshCheck -Major 5
        $c.Status | Should -Be 'Rojo'
        $c.Message | Should -Match 'winget install'
    }
}

Describe 'Get-DsaEnvironmentKindCheck' {
    It 'verde con un Sandbox' { (Get-DsaEnvironmentKindCheck -Kind 'Sandbox').Status | Should -Be 'Verde' }
    It 'amarillo con el predeterminado y remite a ADR-002' {
        $c = Get-DsaEnvironmentKindCheck -Kind 'default'
        $c.Status | Should -Be 'Amarillo'
        $c.Message | Should -Match 'ADR-002'
    }
    It 'rojo con Trial' { (Get-DsaEnvironmentKindCheck -Kind 'trial').Status | Should -Be 'Rojo' }
    It 'rojo sin valor' { (Get-DsaEnvironmentKindCheck -Kind '').Status | Should -Be 'Rojo' }
}

Describe 'Get-DsaAuditCheck' {
    It 'verde si está activada' { (Get-DsaAuditCheck -IsAuditEnabled $true).Status | Should -Be 'Verde' }
    It 'rojo si está desactivada' { (Get-DsaAuditCheck -IsAuditEnabled $false).Status | Should -Be 'Rojo' }
    It 'amarillo si no se pudo consultar' { (Get-DsaAuditCheck -IsAuditEnabled $null).Status | Should -Be 'Amarillo' }
}

Describe 'Get-DsaCreditsCheck' {
    BeforeAll {
        $session = [datetime]'2026-11-04'
        $today = [datetime]'2026-10-26'
    }
    It 'verde con pago por uso' {
        (Get-DsaCreditsCheck -Mode 'paygo' -TrialEnd $null -SessionDate $session -Today $today).Status | Should -Be 'Verde'
    }
    It 'cuenta los días de la capacidad de prueba que llega a la sesión' {
        $c = Get-DsaCreditsCheck -Mode 'prueba' -TrialEnd ([datetime]'2026-11-07') -SessionDate $session -Today $today
        $c.Status | Should -Be 'Verde'
        $c.Message | Should -Match 'faltan 12 días'
    }
    It 'rojo si la prueba vence antes de la sesión' {
        (Get-DsaCreditsCheck -Mode 'prueba' -TrialEnd ([datetime]'2026-11-03') -SessionDate $session -Today $today).Status | Should -Be 'Rojo'
    }
    It 'verde si la prueba vence el mismo día de la sesión' {
        (Get-DsaCreditsCheck -Mode 'prueba' -TrialEnd $session -SessionDate $session -Today $today).Status | Should -Be 'Verde'
    }
    It 'rojo con prueba sin fecha de vencimiento' {
        (Get-DsaCreditsCheck -Mode 'prueba' -TrialEnd $null -SessionDate $session -Today $today).Status | Should -Be 'Rojo'
    }
    It 'amarillo si no se declara el modo' {
        (Get-DsaCreditsCheck -Mode '' -TrialEnd $null -SessionDate $session -Today $today).Status | Should -Be 'Amarillo'
    }
}

Describe 'Get-DsaConsumptionCheck' {
    It 'verde por debajo del 80 %' { (Get-DsaConsumptionCheck -Used 2399 -Limit 3000).Status | Should -Be 'Verde' }
    It 'amarillo desde el 80 %' { (Get-DsaConsumptionCheck -Used 2400 -Limit 3000).Status | Should -Be 'Amarillo' }
    It 'rojo al llegar al límite' { (Get-DsaConsumptionCheck -Used 3000 -Limit 3000).Status | Should -Be 'Rojo' }
    It 'amarillo sin dato' { (Get-DsaConsumptionCheck -Used $null -Limit 3000).Status | Should -Be 'Amarillo' }
}

Describe 'Get-DsaInfrastructureCheck' {
    It 'verde si se declara la nueva infraestructura' { (Get-DsaInfrastructureCheck -Value 'si').Status | Should -Be 'Verde' }
    It 'informa en amarillo si no lo está' { (Get-DsaInfrastructureCheck -Value 'no').Status | Should -Be 'Amarillo' }
    It 'informa en amarillo sin dato' { (Get-DsaInfrastructureCheck -Value $null).Status | Should -Be 'Amarillo' }
}

Describe 'Get-DsaResourceCheck' {
    It 'verde si coincide' { (Get-DsaResourceCheck -Name 'IoT Hub' -Actual 'Active' -Expected 'Active').Status | Should -Be 'Verde' }
    It 'rojo si no coincide' { (Get-DsaResourceCheck -Name 'Function' -Actual 'Stopped' -Expected 'Running').Status | Should -Be 'Rojo' }
    It 'rojo si no se encontró' { (Get-DsaResourceCheck -Name 'Function' -Actual $null -Expected 'Running').Status | Should -Be 'Rojo' }
}

Describe 'Get-DsaEndToEndCheck' {
    It 'verde si llega a Pendiente de decisión a tiempo' {
        (Get-DsaEndToEndCheck -Estado 'Pendiente de decisión' -ElapsedSeconds 28.4 -TimeoutSeconds 90).Status | Should -Be 'Verde'
    }
    It 'rojo si se queda en Nuevo y sugiere retrigger' {
        $c = Get-DsaEndToEndCheck -Estado 'Nuevo' -ElapsedSeconds 90 -TimeoutSeconds 90
        $c.Status | Should -Be 'Rojo'
        $c.Message | Should -Match 'retrigger'
    }
    It 'rojo si no aparece el incidente' {
        (Get-DsaEndToEndCheck -Estado $null -ElapsedSeconds 90 -TimeoutSeconds 90).Status | Should -Be 'Rojo'
    }
    It 'rojo si llega tarde' {
        (Get-DsaEndToEndCheck -Estado 'Pendiente de decisión' -ElapsedSeconds 95 -TimeoutSeconds 90).Status | Should -Be 'Rojo'
    }
}

Describe 'Get-DsaOverallStatus' {
    It 'devuelve el peor estado' {
        $checks = @(
            (New-DsaCheck 'a' 'Verde' 'x'), (New-DsaCheck 'b' 'Amarillo' 'x'), (New-DsaCheck 'c' 'Verde' 'x')
        )
        Get-DsaOverallStatus -Checks $checks | Should -Be 'Amarillo'
        Get-DsaOverallStatus -Checks ($checks + (New-DsaCheck 'd' 'Rojo' 'x')) | Should -Be 'Rojo'
    }
}

Describe 'Select-DsaNewestSince' {
    It 'elige el más reciente creado desde el inicio' {
        $items = @(
            [pscustomobject]@{ Created = '2026-10-26T21:00:00Z'; Estado = 'viejo' },
            [pscustomobject]@{ Created = '2026-10-26T22:00:05Z'; Estado = 'a' },
            [pscustomobject]@{ Created = '2026-10-26T22:00:09Z'; Estado = 'b' }
        )
        (Select-DsaNewestSince -Items $items -Since ([datetime]'2026-10-26T22:00:00Z')).Estado | Should -Be 'b'
    }
    It 'no devuelve nada si todo es anterior' {
        $items = @([pscustomobject]@{ Created = '2026-10-26T21:00:00Z'; Estado = 'viejo' })
        Select-DsaNewestSince -Items $items -Since ([datetime]'2026-10-26T22:00:00Z') | Should -BeNullOrEmpty
    }
}
