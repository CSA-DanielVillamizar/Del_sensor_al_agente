<#
    SPK-01: lógica pura del spike de latencia (sin Graph, sin red, sin reloj real).
    La usan Invoke-LatencySpike.ps1 (modo real y -DryRun), Measure-LatencySpike.ps1 y las pruebas.
    Compatible con Windows PowerShell 5.1 y PowerShell 7.
#>

# Con percentil por rango más cercano, el p90 de Count muestras es la muestra ceil(0.9*Count).
# Si hay más de Count - ceil(0.9*Count) muestras lentas, el p90 queda por encima del objetivo.
function Get-MaxSlow {
    param([Parameter(Mandatory)][int]$Count)
    return [int]($Count - [math]::Ceiling(0.9 * $Count) + 1)
}

# Percentil por rango más cercano. Acepta +Infinito (evento sin reacción).
function Get-Percentile {
    param([Parameter(Mandatory)][double[]]$Values, [Parameter(Mandatory)][double]$P)
    $sorted = @($Values | Sort-Object)
    $rank = [math]::Ceiling($P / 100 * $sorted.Count)
    return [double]$sorted[[math]::Max(0, $rank - 1)]
}

# Un evento es lento si su tramo 2 supera el objetivo, o si no tiene reacción y ya pasó el objetivo.
# Un evento sin reacción nunca se excluye.
function Get-SlowCount {
    param(
        [object[]]$Samples,
        [Parameter(Mandatory)][datetime]$Now,
        [Parameter(Mandatory)][int]$TargetSeconds
    )
    $slow = 0
    foreach ($s in $Samples) {
        if ($null -ne $s.Tramo2) {
            if ([double]$s.Tramo2 -gt $TargetSeconds) { $slow++ }
        }
        elseif (($Now - $s.T0).TotalSeconds -gt $TargetSeconds) { $slow++ }
    }
    return $slow
}

function Test-P90Cut {
    param(
        [object[]]$Samples,
        [Parameter(Mandatory)][datetime]$Now,
        [Parameter(Mandatory)][int]$TargetSeconds,
        [Parameter(Mandatory)][int]$MaxSlow
    )
    return ((Get-SlowCount -Samples $Samples -Now $Now -TargetSeconds $TargetSeconds) -ge $MaxSlow)
}

# Corte de protección: ninguna muestra completó el tramo 2 en CutoffSeconds o menos.
function Test-ProtectionCut {
    param([object[]]$Samples, [Parameter(Mandatory)][int]$CutoffSeconds)
    $within = @($Samples | Where-Object { $null -ne $_.Tramo2 -and [double]$_.Tramo2 -le $CutoffSeconds })
    return ($within.Count -eq 0)
}

<#
    Bucle del spike. El mismo código corre en modo real y en -DryRun; cambian los cuatro scriptblocks:
      Emit    param($i)      -> objeto con EventId, T0 (y lo que necesite Observe)
      Observe param($Sent)   -> objetos con EventId, T0, Tramo2 ($null si aún no hay reacción)
      GetNow                 -> [datetime] UTC actual
      Wait    param($Until)  -> espera hasta $Until (UTC)
    Devuelve Cut ('p90', '60s' o $null), EventsSent y Sent.
#>
function Invoke-SpikeLoop {
    param(
        [Parameter(Mandatory)][int]$Count,
        [Parameter(Mandatory)][int]$IntervalSeconds,
        [Parameter(Mandatory)][int]$CutoffSample,
        [Parameter(Mandatory)][int]$CutoffSeconds,
        [Parameter(Mandatory)][int]$TargetSeconds,
        [Parameter(Mandatory)][scriptblock]$Emit,
        [Parameter(Mandatory)][scriptblock]$Observe,
        [Parameter(Mandatory)][scriptblock]$GetNow,
        [Parameter(Mandatory)][scriptblock]$Wait
    )
    $maxSlow = Get-MaxSlow -Count $Count
    $sent = New-Object System.Collections.Generic.List[object]

    for ($i = 1; $i -le $Count; $i++) {
        # Corte p90: se revisa antes de emitir, para no gastar un evento más.
        if ($sent.Count -ge $maxSlow) {
            $samples = @(& $Observe $sent)
            if (Test-P90Cut -Samples $samples -Now (& $GetNow) -TargetSeconds $TargetSeconds -MaxSlow $maxSlow) {
                return [pscustomobject]@{ Cut = 'p90'; EventsSent = $sent.Count; Sent = $sent.ToArray() }
            }
        }

        $record = & $Emit $i
        $sent.Add($record)

        # Corte de protección: CutoffSeconds después del evento CutoffSample.
        if ($i -eq $CutoffSample -and $i -lt $Count) {
            & $Wait $record.T0.AddSeconds($CutoffSeconds)
            $samples = @(& $Observe $sent)
            if (Test-ProtectionCut -Samples $samples -CutoffSeconds $CutoffSeconds) {
                return [pscustomobject]@{ Cut = '60s'; EventsSent = $sent.Count; Sent = $sent.ToArray() }
            }
            continue
        }

        if ($i -lt $Count) { & $Wait ((& $GetNow).AddSeconds($IntervalSeconds)) }
    }
    return [pscustomobject]@{ Cut = $null; EventsSent = $sent.Count; Sent = $sent.ToArray() }
}

<#
    Driver sintético para -DryRun y pruebas: reloj virtual (Wait no duerme) y latencias inventadas.
    Latencies[i-1] = segundos del tramo 2 del evento i, o $null si nunca hay reacción.
#>
function New-SyntheticDriver {
    param(
        [Parameter(Mandatory)][AllowNull()][object[]]$Latencies,
        [datetime]$Start = [datetime]::new(2026, 1, 1, 0, 0, 0, [DateTimeKind]::Utc)
    )
    $state = @{ Now = $Start; Latencies = $Latencies }
    return @{
        State   = $state
        GetNow  = { $state.Now }.GetNewClosure()
        Wait    = { param($Until) if ($Until -gt $state.Now) { $state.Now = $Until } }.GetNewClosure()
        Emit    = { param($i) [pscustomobject]@{ EventId = "sim-$i"; T0 = $state.Now; Index = $i } }.GetNewClosure()
        Observe = {
            param($Sent)
            foreach ($s in $Sent) {
                $lat = $null
                if ($s.Index -le $state.Latencies.Count) { $lat = $state.Latencies[$s.Index - 1] }
                $tramo2 = $null
                if ($null -ne $lat -and $s.T0.AddSeconds([double]$lat) -le $state.Now) { $tramo2 = [double]$lat }
                [pscustomobject]@{ EventId = $s.EventId; T0 = $s.T0; Tramo2 = $tramo2 }
            }
        }.GetNewClosure()
    }
}

<#
    Resumen por opción. Cada fila: Opcion, Reaccion, Tramo2 (segundos o $null) y Vencido (sin reacción
    al agotar el tiempo de espera). Los vencidos entran al cálculo como +Infinito: nunca se excluyen.
    Las filas aún pendientes (sin reacción y sin vencer) dejan la opción como "Pendiente".
#>
function Get-SpikeSummary {
    param(
        [Parameter(Mandatory)][object[]]$Rows,
        [hashtable]$Cuts = @{},
        [int]$TargetSeconds = 20
    )
    foreach ($group in $Rows | Group-Object Opcion | Sort-Object Name) {
        $final = @($group.Group | Where-Object { $null -ne $_.Tramo2 -or $_.Vencido })
        $lost = @($group.Group | Where-Object { $_.Vencido }).Count
        $pending = @($group.Group | Where-Object { $null -eq $_.Tramo2 -and -not $_.Vencido }).Count

        $t = @($final | ForEach-Object { if ($_.Vencido) { [double]::PositiveInfinity } else { [double]$_.Tramo2 } })
        $r = @($final | ForEach-Object { if ($_.Vencido) { [double]::PositiveInfinity } else { [double]$_.Reaccion } })

        $p50 = $null; $p90 = $null; $max = $null; $r50 = $null; $r90 = $null
        if ($t.Count -gt 0) {
            $p50 = Get-Percentile -Values $t -P 50
            $p90 = Get-Percentile -Values $t -P 90
            $max = [double]($t | Measure-Object -Maximum).Maximum
            $r50 = Get-Percentile -Values $r -P 50
            $r90 = Get-Percentile -Values $r -P 90
        }

        if ($Cuts.ContainsKey($group.Name)) { $verdict = "No (corte $($Cuts[$group.Name]))" }
        elseif ($pending -gt 0) { $verdict = 'Pendiente' }
        elseif ($t.Count -gt 0 -and $lost -eq 0 -and $p90 -le $TargetSeconds) { $verdict = 'Cumple' }
        else { $verdict = 'No cumple' }

        [pscustomobject]@{
            Opcion      = $group.Name
            N           = $group.Count
            SinReaccion = $lost
            Pendientes  = $pending
            ReaccionP50 = $r50
            ReaccionP90 = $r90
            Tramo2P50   = $p50
            Tramo2P90   = $p90
            Tramo2Max   = $max
            Veredicto   = $verdict
        }
    }
}

function Format-Seconds {
    param($Value)
    if ($null -eq $Value) { return '-' }
    if ([double]::IsInfinity([double]$Value)) { return 'sin reacción' }
    return ('{0:N1} s' -f [double]$Value)
}

function ConvertTo-SpikeMarkdown {
    param([object[]]$Summary, [datetime]$GeneratedUtc, [int]$TargetSeconds = 20)
    $lines = @(
        '# SPK-01 - Resultados',
        '',
        "Generado: $($GeneratedUtc.ToString('yyyy-MM-dd HH:mm')) UTC. Umbral de decisión: p90 del tramo 2 <= $TargetSeconds s, sin eventos perdidos.",
        '',
        '| Opción | n | Sin reacción | Reacción p50 | Reacción p90 | Tramo 2 p50 | Tramo 2 p90 | Tramo 2 máx | Veredicto |',
        '| --- | --- | --- | --- | --- | --- | --- | --- | --- |'
    )
    foreach ($s in $Summary) {
        $lines += ('| {0} | {1} | {2} | {3} | {4} | {5} | {6} | {7} | {8} |' -f $s.Opcion, $s.N, $s.SinReaccion,
            (Format-Seconds $s.ReaccionP50), (Format-Seconds $s.ReaccionP90), (Format-Seconds $s.Tramo2P50),
            (Format-Seconds $s.Tramo2P90), (Format-Seconds $s.Tramo2Max), $s.Veredicto)
    }
    $pending = ($Summary | Measure-Object -Property Pendientes -Sum).Sum
    if ($pending -gt 0) { $lines += '', "Atención: $pending eventos aún dentro del tiempo de espera; vuelve a ejecutar más tarde." }
    return $lines
}

Export-ModuleMember -Function Get-MaxSlow, Get-Percentile, Get-SlowCount, Test-P90Cut, Test-ProtectionCut,
    Invoke-SpikeLoop, New-SyntheticDriver, Get-SpikeSummary, Format-Seconds, ConvertTo-SpikeMarkdown
