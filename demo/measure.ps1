#Requires -Version 7.0
<#
.SYNOPSIS
    T-040 (HU-08 CA-08.6, RNF-01): mide el tramo 2 (elemento creado → tarjeta visible) y el total
    (RecibidoUtc → tarjeta visible) de los últimos N incidentes, con los percentiles de SpikeLogic.psm1.

.DESCRIPTION
    Une los elementos de "Eventos de seguridad" con los mensajes del canal "Centro de operaciones" por el texto
    "Ref. {eventId}" de la tarjeta (plan §7). La tarjeta visible es el createdDateTime del primer mensaje con esa
    referencia. El tramo 1 que muestra es aproximado (createdDateTime − RecibidoUtc); el oficial es la KQL
    infra/queries/tramo1.kql (CA-05.5).

    Identidad: sesión delegada e interactiva del operador con Microsoft Graph (módulo Microsoft.Graph.Authentication):
      Sites.Read.All y ChannelMessage.Read.All (List channel messages, permiso delegado de menor privilegio).
      Si no defines DSA_TEAM_ID y DSA_CHANNEL_ID, busca el equipo y el canal por nombre y pide además
      Team.ReadBasic.All y Channel.ReadBasic.All.

    Variables de entorno: DSA_SITE_URL, DSA_LIST_NAME, DSA_TEAM_NAME, DSA_CHANNEL_NAME y, opcionales,
    DSA_TEAM_ID y DSA_CHANNEL_ID. Solo lee: no cambia la lista ni el canal.

.EXAMPLE
    ./demo/measure.ps1 -Last 10
#>
[CmdletBinding()]
param(
    [ValidateRange(1, 500)][int]$Last = 10,
    # Un incidente sin tarjeta pasado este tiempo cuenta como "sin tarjeta" (+Infinito).
    [ValidateRange(10, 3600)][int]$TimeoutSeconds = 60,
    [ValidateRange(1, 100)][int]$MaxMessagePages = 10,
    # Archivo Markdown opcional para el resultado. No lo guardes dentro del repositorio.
    [string]$OutFile
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'DemoLogic.psm1') -Force

function Get-RequiredEnv([string]$Name) {
    $value = [Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrWhiteSpace($value)) { throw "Falta la variable de entorno $Name (ver .env.example)." }
    return $value
}

function Get-AllPages([string]$Uri, [int]$MaxPages = 1000) {
    $page = 0
    while ($Uri -and $page -lt $MaxPages) {
        $r = Invoke-MgGraphRequest -Method GET -Uri $Uri
        foreach ($v in $r.value) { $v }
        $Uri = $r.'@odata.nextLink'
        $page++
    }
}

$siteUrl = [uri](Get-RequiredEnv 'DSA_SITE_URL')
$listName = [Environment]::GetEnvironmentVariable('DSA_LIST_NAME')
if ([string]::IsNullOrWhiteSpace($listName)) { $listName = 'Eventos de seguridad' }
$teamId = [Environment]::GetEnvironmentVariable('DSA_TEAM_ID')
$channelId = [Environment]::GetEnvironmentVariable('DSA_CHANNEL_ID')

$scopes = @('Sites.Read.All', 'ChannelMessage.Read.All')
if (-not ($teamId -and $channelId)) { $scopes += @('Team.ReadBasic.All', 'Channel.ReadBasic.All') }

Import-Module Microsoft.Graph.Authentication
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'sharepoint' 'ProvisionLogic.psm1') -Force
# Reutiliza una sesión delegada del mismo proceso si ya tiene los permisos (Sites.ReadWrite.All también sirve para leer).
$context = Get-MgContext
$granted = if ($context) { @($context.Scopes) } else { @() }
if ((Get-DsaMissingScopes -Granted $granted -Required @('Sites.ReadWrite.All')).Count -eq 0) { $scopes = @($scopes | Where-Object { $_ -ne 'Sites.Read.All' }) }
if (-not $context -or $context.AuthType -ne 'Delegated' -or (Get-DsaMissingScopes -Granted $granted -Required $scopes).Count -gt 0) {
    # -ContextScope Process: el token vive solo en este proceso, no en la caché del perfil.
    Connect-MgGraph -Scopes $scopes -ContextScope Process -NoWelcome
}

# 1. Elementos de la lista.
$site = Invoke-MgGraphRequest -Method GET -Uri "v1.0/sites/$($siteUrl.Host):$($siteUrl.AbsolutePath.TrimEnd('/'))?`$select=id"
$filter = [uri]::EscapeDataString("displayName eq '$listName'")
$list = (Invoke-MgGraphRequest -Method GET -Uri "v1.0/sites/$($site.id)/lists?`$filter=$filter&`$select=id").value |
    Select-Object -First 1
if (-not $list) { throw "No existe la lista '$listName' en el sitio de la demo." }

$itemsUri = "v1.0/sites/$($site.id)/lists/$($list.id)/items?`$select=id,createdDateTime&`$expand=fields(`$select=EventId,RecibidoUtc)&`$top=200"
$items = @(Get-AllPages $itemsUri | ForEach-Object {
        [pscustomobject]@{
            EventId     = $_.fields.EventId
            CreatedUtc  = ConvertTo-UtcDateTime $_.createdDateTime
            RecibidoUtc = ConvertTo-UtcDateTime $_.fields.RecibidoUtc
        }
    } | Where-Object { $_.EventId })
$selected = Select-LastItems -Items $items -Last $Last
if ($selected.Count -eq 0) { throw 'La lista no tiene incidentes.' }

# 2. Mensajes del canal.
if (-not ($teamId -and $channelId)) {
    $teamName = Get-RequiredEnv 'DSA_TEAM_NAME'
    $channelName = Get-RequiredEnv 'DSA_CHANNEL_NAME'
    $teamId = (Get-AllPages 'v1.0/me/joinedTeams?$select=id,displayName' | Where-Object { $_.displayName -eq $teamName } |
            Select-Object -First 1).id
    if (-not $teamId) { throw "No perteneces a un equipo llamado '$teamName'." }
    $channelId = (Get-AllPages "v1.0/teams/$teamId/channels?`$select=id,displayName" |
            Where-Object { $_.displayName -eq $channelName } | Select-Object -First 1).id
    if (-not $channelId) { throw "El equipo no tiene un canal llamado '$channelName'." }
}
$messages = @(Get-AllPages "v1.0/teams/$teamId/channels/$channelId/messages?`$top=50" -MaxPages $MaxMessagePages)

# 3. Unión y percentiles (lógica pura, demo/tests).
$now = [DateTime]::UtcNow
$rows = @(Join-IncidentMessages -Items $selected -Messages $messages -Now $now -TimeoutSeconds $TimeoutSeconds)
$rows | Format-Table EventId, @{ n = 'Tramo1 s'; e = { $_.Tramo1 } }, @{ n = 'Tramo2 s'; e = { $_.Tramo2 } },
    @{ n = 'Total s'; e = { $_.Total } }, Vencido -AutoSize | Out-Host

$summary = Get-LatencySummary -Rows $rows
$lines = ConvertTo-LatencyMarkdown -Summary $summary -GeneratedUtc $now
$lines | Write-Host
if ($OutFile) { $lines | Set-Content -Path $OutFile -Encoding utf8 }
