#Requires -Version 7.0
<#
    T-047 (HU-14 CA-14.3): lógica pura de demo/preflight.ps1.
    Cada función recibe datos ya obtenidos y devuelve un resultado verde, amarillo o rojo con su mensaje.
    Sin red, sin az y sin Graph: el script consulta y este módulo decide.
#>

$script:Order = @{ Verde = 0; Amarillo = 1; Rojo = 2 }

function New-DsaCheck {
    param(
        [Parameter(Mandatory)][string] $Name,
        [Parameter(Mandatory)][ValidateSet('Verde', 'Amarillo', 'Rojo')][string] $Status,
        [Parameter(Mandatory)][string] $Message
    )
    return [pscustomobject]@{ Name = $Name; Status = $Status; Message = $Message }
}

# PowerShell 7 o superior; si no, rojo con el comando de instalación.
function Get-DsaPwshCheck {
    param([Parameter(Mandatory)][int] $Major)
    if ($Major -ge 7) { return New-DsaCheck 'PowerShell' 'Verde' "PowerShell $Major." }
    return New-DsaCheck 'PowerShell' 'Rojo' "PowerShell $Major. Instala PowerShell 7: winget install --id Microsoft.PowerShell --source winget"
}

# Entorno de Power Platform declarado en .env (DSA_ENVIRONMENT_KIND).
function Get-DsaEnvironmentKindCheck {
    param([string] $Kind)
    switch (($Kind ?? '').Trim().ToLowerInvariant()) {
        'sandbox' { return New-DsaCheck 'Entorno' 'Verde' 'Sandbox dedicado (configuración recomendada).' }
        'default' { return New-DsaCheck 'Entorno' 'Amarillo' 'Entorno predeterminado del tenant: desviación aceptada en docs/adr/ADR-002-entorno-demo-en-vivo.md.' }
        'trial' { return New-DsaCheck 'Entorno' 'Rojo' 'Entorno Trial: se elimina con sus agentes a los 30 días y no admite pago por uso.' }
        default { return New-DsaCheck 'Entorno' 'Rojo' "DSA_ENVIRONMENT_KIND no es sandbox ni default ('$Kind')." }
    }
}

# Auditoría de Dataverse (isauditenabled de la organización). $null = no se pudo consultar.
function Get-DsaAuditCheck {
    param([AllowNull()][object] $IsAuditEnabled)
    if ($null -eq $IsAuditEnabled) { return New-DsaCheck 'Auditoría de Dataverse' 'Amarillo' 'No se pudo consultar: define DSA_DATAVERSE_URL y revisa la sesión de az.' }
    if ([bool]$IsAuditEnabled) { return New-DsaCheck 'Auditoría de Dataverse' 'Verde' 'Activada.' }
    return New-DsaCheck 'Auditoría de Dataverse' 'Rojo' 'Desactivada: actívala en el centro de administración de Power Platform.'
}

# Cómo se pagan los créditos y, si la capacidad es de prueba, cuántos días faltan.
function Get-DsaCreditsCheck {
    param(
        [string] $Mode,
        [AllowNull()][Nullable[datetime]] $TrialEnd,
        [Parameter(Mandatory)][datetime] $SessionDate,
        [Parameter(Mandatory)][datetime] $Today
    )
    switch (($Mode ?? '').Trim().ToLowerInvariant()) {
        'paygo' { return New-DsaCheck 'Créditos' 'Verde' 'Pago por uso vinculado al entorno.' }
        'capacidad' { return New-DsaCheck 'Créditos' 'Verde' 'Capacidad del tenant (sin vencimiento declarado).' }
        'prueba' {
            if ($null -eq $TrialEnd) { return New-DsaCheck 'Créditos' 'Rojo' 'Capacidad de prueba sin DSA_TRIAL_END: no se puede saber si llega a la sesión.' }
            $days = [int][math]::Floor(($TrialEnd.Date - $Today.Date).TotalDays)
            if ($TrialEnd.Date -lt $SessionDate.Date) {
                return New-DsaCheck 'Créditos' 'Rojo' ("Capacidad de prueba: vence el {0:yyyy-MM-dd}, antes de la sesión ({1:yyyy-MM-dd})." -f $TrialEnd, $SessionDate)
            }
            return New-DsaCheck 'Créditos' 'Verde' ("Capacidad de prueba: faltan {0} días para el vencimiento ({1:yyyy-MM-dd}); la sesión es el {2:yyyy-MM-dd}." -f $days, $TrialEnd, $SessionDate)
        }
        default { return New-DsaCheck 'Créditos' 'Amarillo' "DSA_CREDITS_MODE no declarado ('$Mode'): usa paygo, capacidad o prueba." }
    }
}

# Consumo del mes frente al límite del agente: rojo desde el 100 %, amarillo desde el 80 %.
function Get-DsaConsumptionCheck {
    param([AllowNull()][Nullable[double]] $Used, [Parameter(Mandatory)][double] $Limit)
    if ($null -eq $Used) {
        return New-DsaCheck 'Consumo de créditos' 'Amarillo' 'Sin dato: revisa el consumo del agente en el centro de administración de Power Platform y defínelo en DSA_CREDITS_USED.'
    }
    $pct = if ($Limit -gt 0) { 100 * $Used / $Limit } else { 100 }
    $text = '{0:N0} de {1:N0} créditos ({2:N0} %).' -f $Used, $Limit, $pct
    if ($pct -ge 100) { return New-DsaCheck 'Consumo de créditos' 'Rojo' "$text Se alcanzó el límite del agente." }
    if ($pct -ge 80) { return New-DsaCheck 'Consumo de créditos' 'Amarillo' "$text Pasa del 80 % del límite." }
    return New-DsaCheck 'Consumo de créditos' 'Verde' $text
}

# Nueva infraestructura de Power Platform: verde si se declara, si no se informa en amarillo.
function Get-DsaInfrastructureCheck {
    param([string] $Value)
    switch (($Value ?? '').Trim().ToLowerInvariant()) {
        'si' { return New-DsaCheck 'Infraestructura de Power Platform' 'Verde' 'El entorno está en la nueva infraestructura.' }
        'no' { return New-DsaCheck 'Infraestructura de Power Platform' 'Amarillo' 'El entorno no está en la nueva infraestructura.' }
        default { return New-DsaCheck 'Infraestructura de Power Platform' 'Amarillo' 'Sin dato: confírmalo en el centro de administración y defínelo en DSA_NEW_INFRA (si o no).' }
    }
}

# Estado de un recurso de Azure frente al valor esperado.
function Get-DsaResourceCheck {
    param([Parameter(Mandatory)][string] $Name, [AllowNull()][string] $Actual, [Parameter(Mandatory)][string] $Expected)
    if ([string]::IsNullOrWhiteSpace($Actual)) { return New-DsaCheck $Name 'Rojo' 'No se encontró o no se pudo consultar.' }
    if ($Actual -eq $Expected) { return New-DsaCheck $Name 'Verde' $Actual }
    return New-DsaCheck $Name 'Rojo' "Estado $Actual (se esperaba $Expected)."
}

# Prueba de punta a punta: el incidente EsPrueba llega a Pendiente de decisión dentro del tiempo límite.
function Get-DsaEndToEndCheck {
    param([AllowNull()][string] $Estado, [Parameter(Mandatory)][double] $ElapsedSeconds, [Parameter(Mandatory)][int] $TimeoutSeconds)
    if ($Estado -eq 'Pendiente de decisión' -and $ElapsedSeconds -le $TimeoutSeconds) {
        return New-DsaCheck 'Punta a punta' 'Verde' ('Pendiente de decisión en {0:N1} s.' -f $ElapsedSeconds)
    }
    if ([string]::IsNullOrWhiteSpace($Estado)) {
        return New-DsaCheck 'Punta a punta' 'Rojo' ('No apareció el incidente en {0} s: revisa la Function y IoT Hub.' -f $TimeoutSeconds)
    }
    return New-DsaCheck 'Punta a punta' 'Rojo' ('El incidente quedó en "{0}" a los {1} s: revisa DisparoAgente y el agente (demo/retrigger.ps1).' -f $Estado, $TimeoutSeconds)
}

# El peor estado de todos los resultados.
function Get-DsaOverallStatus {
    param([Parameter(Mandatory)][object[]] $Checks)
    $worst = 'Verde'
    foreach ($c in $Checks) { if ($script:Order[$c.Status] -gt $script:Order[$worst]) { $worst = $c.Status } }
    return $worst
}

function Format-DsaCheck {
    param([Parameter(Mandatory)][object] $Check)
    $colors = @{ Verde = 'Green'; Amarillo = 'Yellow'; Rojo = 'Red' }
    return [pscustomobject]@{
        Text  = ('[{0,-8}] {1}: {2}' -f $Check.Status.ToLowerInvariant(), $Check.Name, $Check.Message)
        Color = $colors[$Check.Status]
    }
}

# Elige el elemento más reciente creado desde el inicio de la prueba.
function Select-DsaNewestSince {
    param([object[]] $Items, [Parameter(Mandatory)][datetime] $Since)
    return @($Items | Where-Object { $_ -and ([datetime]$_.Created).ToUniversalTime() -ge $Since.ToUniversalTime() } |
            Sort-Object { ([datetime]$_.Created).ToUniversalTime() } -Descending) | Select-Object -First 1
}

Export-ModuleMember -Function @(
    'New-DsaCheck', 'Get-DsaPwshCheck', 'Get-DsaEnvironmentKindCheck', 'Get-DsaAuditCheck', 'Get-DsaCreditsCheck',
    'Get-DsaConsumptionCheck', 'Get-DsaInfrastructureCheck', 'Get-DsaResourceCheck', 'Get-DsaEndToEndCheck',
    'Get-DsaOverallStatus', 'Format-DsaCheck', 'Select-DsaNewestSince'
)
