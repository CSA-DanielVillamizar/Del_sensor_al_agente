#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
    Pruebas de la lógica de corte y del resumen de SPK-01, con tiempos sintéticos (cero créditos).
    Ejecutar desde spikes/p1-latencia:  Invoke-Pester ./tests -Output Detailed
#>

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'SpikeLogic.psm1') -Force

    # Ejecuta el bucle real del spike con reloj virtual y parámetros por defecto de Invoke-LatencySpike.ps1.
    function Invoke-Sim {
        param([AllowNull()][object[]]$Latencies, [int]$TargetSeconds = 20, [int]$Count = 20)
        $driver = New-SyntheticDriver -Latencies $Latencies
        Invoke-SpikeLoop -Count $Count -IntervalSeconds 45 -CutoffSample 5 -CutoffSeconds 60 `
            -TargetSeconds $TargetSeconds -Emit $driver.Emit -Observe $driver.Observe `
            -GetNow $driver.GetNow -Wait $driver.Wait
    }

    # Latencias de 20 eventos: todas iguales salvo las posiciones (1-based) indicadas.
    function New-Latencies {
        param([double]$Default = 5, [hashtable]$At = @{})
        $list = [System.Collections.Generic.List[object]]::new()
        for ($i = 1; $i -le 20; $i++) { $list.Add($(if ($At.ContainsKey($i)) { $At[$i] } else { $Default })) }
        , $list.ToArray()
    }

    function New-Row([string]$Opcion, $Tramo2, $Reaccion = $null, [bool]$Vencido = $false) {
        [pscustomobject]@{ Opcion = $Opcion; Reaccion = $Reaccion; Tramo2 = $Tramo2; Vencido = $Vencido }
    }
}

Describe 'Get-MaxSlow' {
    It 'con 20 muestras el p90 es imposible a partir de 3 muestras lentas' {
        Get-MaxSlow -Count 20 | Should -Be 3
    }
    It 'con 10 muestras basta con 2' {
        Get-MaxSlow -Count 10 | Should -Be 2
    }
}

Describe 'Bucle del spike: cortes' {
    It 'caso 1: 20 eventos rápidos (< 20 s) completan las muestras sin corte' {
        $r = Invoke-Sim (New-Latencies -Default 5)
        $r.Cut | Should -BeNullOrEmpty
        $r.EventsSent | Should -Be 20
    }

    It 'caso 2: el tercer evento lento llega en la posición 7 y corta por p90 en el evento 7' {
        $r = Invoke-Sim (New-Latencies -Default 5 -At @{ 2 = 30; 4 = 30; 7 = 30 })
        $r.Cut | Should -Be 'p90'
        $r.EventsSent | Should -Be 7
    }

    It 'caso 2b: dos eventos lentos no bastan para cortar' {
        $r = Invoke-Sim (New-Latencies -Default 5 -At @{ 2 = 30; 4 = 30 })
        $r.Cut | Should -BeNullOrEmpty
        $r.EventsSent | Should -Be 20
    }

    It 'caso 3: los 5 primeros > 60 s cortan por 60s en el evento 5 (con el corte p90 neutralizado)' {
        $r = Invoke-Sim (New-Latencies -Default 5 -At @{ 1 = 120; 2 = 120; 3 = 120; 4 = 120; 5 = 120 }) -TargetSeconds 600
        $r.Cut | Should -Be '60s'
        $r.EventsSent | Should -Be 5
    }

    It 'caso 3b: con los parámetros por defecto, el corte p90 actúa antes, en el evento 3' {
        $r = Invoke-Sim (New-Latencies -Default 5 -At @{ 1 = 120; 2 = 120; 3 = 120; 4 = 120; 5 = 120 })
        $r.Cut | Should -Be 'p90'
        $r.EventsSent | Should -Be 3
    }

    It 'caso 4: un evento sin reacción cuenta como lento (corte en el evento 6 con dos sin reacción y uno lento)' {
        $r = Invoke-Sim (New-Latencies -Default 5 -At @{ 2 = $null; 4 = $null; 6 = 30 })
        $r.Cut | Should -Be 'p90'
        $r.EventsSent | Should -Be 6
    }
}

Describe 'Get-SlowCount: eventos sin reacción' {
    BeforeAll { $t0 = [datetime]::new(2026, 1, 1, 0, 0, 0, [DateTimeKind]::Utc) }

    It 'cuenta como lento un evento sin reacción que ya superó el objetivo' {
        $s = @([pscustomobject]@{ T0 = $t0; Tramo2 = $null })
        Get-SlowCount -Samples $s -Now $t0.AddSeconds(21) -TargetSeconds 20 | Should -Be 1
    }
    It 'no lo cuenta todavía si aún no pasó el objetivo' {
        $s = @([pscustomobject]@{ T0 = $t0; Tramo2 = $null })
        Get-SlowCount -Samples $s -Now $t0.AddSeconds(10) -TargetSeconds 20 | Should -Be 0
    }
}

Describe 'Get-SpikeSummary (Measure-LatencySpike)' {
    It 'caso 5: calcula p50, p90 y máximo correctos sobre 1..20 s' {
        $rows = 1..20 | ForEach-Object { New-Row 'A' ([double]$_) ([double]($_ - 1)) }
        $s = Get-SpikeSummary -Rows $rows
        $s.N | Should -Be 20
        $s.Tramo2P50 | Should -Be 10
        $s.Tramo2P90 | Should -Be 18
        $s.Tramo2Max | Should -Be 20
        $s.ReaccionP50 | Should -Be 9
        $s.ReaccionP90 | Should -Be 17
        $s.Veredicto | Should -Be 'Cumple'
    }

    It 'caso 5b: p90 de 21 s no cumple' {
        $values = @(1..17) + @(21, 22, 23)
        $rows = $values | ForEach-Object { New-Row 'A' ([double]$_) ([double]$_) }
        $s = Get-SpikeSummary -Rows $rows
        $s.Tramo2P90 | Should -Be 21
        $s.Veredicto | Should -Be 'No cumple'
    }

    It 'caso 4b: un evento sin reacción no se excluye: cuenta en n, el máximo es "sin reacción" y la opción no cumple' {
        $rows = @(1..19 | ForEach-Object { New-Row 'B' 5.0 4.0 }) + @(New-Row 'B' $null $null $true)
        $s = Get-SpikeSummary -Rows $rows
        $s.N | Should -Be 20
        $s.SinReaccion | Should -Be 1
        [double]::IsPositiveInfinity($s.Tramo2Max) | Should -BeTrue
        (Format-Seconds $s.Tramo2Max) | Should -Be 'sin reacción'
        $s.Veredicto | Should -Be 'No cumple'
    }

    It 'un evento aún dentro del tiempo de espera deja la opción como "Pendiente"' {
        $rows = @(1..19 | ForEach-Object { New-Row 'A' 5.0 4.0 }) + @(New-Row 'A' $null $null $false)
        (Get-SpikeSummary -Rows $rows).Veredicto | Should -Be 'Pendiente'
    }

    It 'un corte registrado manda sobre las métricas' {
        $rows = 1..3 | ForEach-Object { New-Row 'A' 30.0 29.0 }
        (Get-SpikeSummary -Rows $rows -Cuts @{ A = 'p90' }).Veredicto | Should -Be 'No (corte p90)'
    }

    It 'separa las opciones y las ordena' {
        $rows = @(New-Row 'B' 5.0 4.0) + @(New-Row 'A' 5.0 4.0)
        (Get-SpikeSummary -Rows $rows).Opcion | Should -Be @('A', 'B')
    }
}

Describe 'Invoke-LatencySpike.ps1 -DryRun' {
    It 'usa el mismo bucle sin conectarse a nada y corta en el evento 7' {
        $script = Join-Path $PSScriptRoot '..' 'Invoke-LatencySpike.ps1'
        $lat = New-Latencies -Default 5 -At @{ 2 = 30; 4 = 30; 7 = 30 }
        $r = & $script -Option A -DryRun -SyntheticLatency $lat 6>$null
        $r.Cut | Should -Be 'p90'
        $r.EventsSent | Should -Be 7
    }
}
