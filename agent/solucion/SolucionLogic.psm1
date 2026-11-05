# Lógica de empaquetado de la solución de Power Platform "Del sensor al agente".
# La carpeta src/ guarda la solución exportada (no administrada) con marcadores
# {{DSA_*}} en lugar de los valores propios de cada tenant. Este módulo los
# reemplaza y arma el .zip que se importa en Copilot Studio o Power Apps.

Set-StrictMode -Version Latest

# Marcadores admitidos y la variable de entorno de la que sale cada valor.
$script:DsaSolutionMarkers = [ordered]@{
    '{{DSA_SITE_URL}}'           = 'DSA_SITE_URL'
    '{{DSA_TEAM_ID}}'            = 'DSA_TEAM_ID'
    '{{DSA_CHANNEL_ID}}'         = 'DSA_CHANNEL_ID'
    '{{DSA_FLOW_ALLOWED_USERS}}' = 'DSA_FLOW_ALLOWED_USERS'
}

function Get-DsaSolutionMarkers {
    <# Devuelve el mapa marcador -> variable de entorno. #>
    return $script:DsaSolutionMarkers
}

function Test-DsaSolutionValues {
    <#
    Valida los valores antes de empaquetar. Devuelve la lista de errores
    (vacía si todo está bien).
    #>
    param([Parameter(Mandatory)][hashtable] $Values)

    $errors = [System.Collections.Generic.List[string]]::new()
    foreach ($marker in $script:DsaSolutionMarkers.Keys) {
        $name = $script:DsaSolutionMarkers[$marker]
        if (-not $Values.ContainsKey($marker) -or [string]::IsNullOrWhiteSpace($Values[$marker])) {
            $errors.Add("Falta $name.")
        }
    }
    if ($errors.Count -gt 0) { return $errors.ToArray() }

    $guid = '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
    if ($Values['{{DSA_SITE_URL}}'] -notmatch '^https://[^/]+\.sharepoint\.com/sites/[^/]+$') {
        $errors.Add('DSA_SITE_URL debe ser la URL del sitio, sin barra final: https://<tenant>.sharepoint.com/sites/<sitio>.')
    }
    if ($Values['{{DSA_TEAM_ID}}'] -notmatch "^$guid$") {
        $errors.Add('DSA_TEAM_ID debe ser el identificador (GUID) del equipo de Teams.')
    }
    if ($Values['{{DSA_CHANNEL_ID}}'] -notmatch '^19:.+@thread\.(tacv2|skype)$') {
        $errors.Add('DSA_CHANNEL_ID debe ser el identificador del canal: 19:...@thread.tacv2.')
    }
    if ($Values['{{DSA_FLOW_ALLOWED_USERS}}'] -notmatch "^$guid(;$guid)*$") {
        $errors.Add('DSA_FLOW_ALLOWED_USERS debe ser uno o más ObjectId separados por punto y coma.')
    }
    return $errors.ToArray()
}

function ConvertTo-DsaSolutionText {
    <# Reemplaza cada marcador por su valor en un texto. #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string] $Text,
        [Parameter(Mandatory)][hashtable] $Values
    )
    foreach ($marker in $script:DsaSolutionMarkers.Keys) {
        $Text = $Text.Replace($marker, $Values[$marker])
    }
    return $Text
}

function New-DsaSolutionPackage {
    <#
    Copia src/ a una carpeta temporal, reemplaza los marcadores y crea el .zip.
    Falla si queda algún marcador sin reemplazar. Devuelve la ruta del .zip.
    #>
    param(
        [Parameter(Mandatory)][string] $SourcePath,
        [Parameter(Mandatory)][string] $OutputZip,
        [Parameter(Mandatory)][hashtable] $Values
    )

    $errors = @(Test-DsaSolutionValues -Values $Values)
    if ($errors.Count -gt 0) { throw ($errors -join ' ') }

    $source = (Resolve-Path -LiteralPath $SourcePath).Path
    $utf8 = [System.Text.UTF8Encoding]::new($false)
    $outDir = Split-Path -Parent $OutputZip
    if ($outDir -and -not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Path $outDir | Out-Null }
    if (Test-Path -LiteralPath $OutputZip) { Remove-Item -LiteralPath $OutputZip }

    Add-Type -AssemblyName System.IO.Compression
    $stream = [System.IO.File]::Open($OutputZip, [System.IO.FileMode]::CreateNew)
    $zip = [System.IO.Compression.ZipArchive]::new($stream, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($file in Get-ChildItem -LiteralPath $source -Recurse -File) {
            $entryName = $file.FullName.Substring($source.Length).TrimStart('\', '/').Replace('\', '/')
            $bytes = [System.IO.File]::ReadAllBytes($file.FullName)
            $text = $utf8.GetString($bytes)
            if ($text.Contains('{{DSA_')) {
                $text = ConvertTo-DsaSolutionText -Text $text -Values $Values
                if ($text -match '\{\{DSA_[A-Z_]+\}\}') { throw "Marcador sin reemplazar en $entryName : $($Matches[0])" }
                $bytes = $utf8.GetBytes($text)
            }
            $entry = $zip.CreateEntry($entryName, [System.IO.Compression.CompressionLevel]::Optimal)
            $writer = $entry.Open()
            try { $writer.Write($bytes, 0, $bytes.Length) } finally { $writer.Dispose() }
        }
    }
    finally {
        $zip.Dispose()
        $stream.Dispose()
    }
    return $OutputZip
}

Export-ModuleMember -Function Get-DsaSolutionMarkers, Test-DsaSolutionValues, ConvertTo-DsaSolutionText, New-DsaSolutionPackage
