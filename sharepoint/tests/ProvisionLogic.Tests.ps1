#Requires -Version 7.0
# T-029 (HU-07 CA-07.1, CA-07.2): pruebas de la lógica pura de sharepoint/provision.ps1.
# Sin red ni tenant: el estado de SharePoint se simula con hashtables como los de Invoke-MgGraphRequest.

BeforeAll {
    $script:Root = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    Import-Module (Join-Path $script:Root 'sharepoint' 'ProvisionLogic.psm1') -Force
    $script:Contract = Get-Content (Join-Path $script:Root 'sharepoint' 'columnas.json') -Raw -Encoding utf8 | ConvertFrom-Json
    $script:Columns = Assert-DsaColumnContract -Contract $script:Contract

    # Simula lo que devuelve Graph después de crear cada columna: el cuerpo del POST más un id.
    function New-FakeExisting {
        param([object[]] $Columns)
        $list = foreach ($column in $Columns) {
            if ($column.builtIn) {
                @{ id = "id-$($column.name)"; name = $column.name; displayName = 'Title'; required = $true; text = @{ allowMultipleLines = $false } }
                continue
            }
            $body = New-DsaColumnBody -Column $column
            $fake = @{ id = "id-$($column.name)" }
            foreach ($key in $body.Keys) { $fake[$key] = $body[$key] }
            if (-not $fake.ContainsKey('indexed')) { $fake.indexed = $false }
            if (-not $fake.ContainsKey('enforceUniqueValues')) { $fake.enforceUniqueValues = $false }
            $fake
        }
        # Columnas propias de SharePoint que no están en el contrato.
        $list += @{ id = 'id-Created'; name = 'Created'; displayName = 'Created'; required = $false; dateTime = @{} }
        $list += @{ id = 'id-ContentType'; name = 'ContentType'; displayName = 'Content Type'; required = $false; choice = @{ choices = @() } }
        return , @($list)
    }
}

Describe 'ConvertFrom-DsaDotEnv' {
    It 'lee claves, ignora comentarios y quita comillas' {
        $env = ConvertFrom-DsaDotEnv -Lines @('# comentario', '', 'DSA_SITE_URL=https://contoso.sharepoint.com/sites/x', 'DSA_LIST_NAME="Eventos de seguridad"', "DSA_X='a'", 'SIN_IGUAL')
        $env['DSA_SITE_URL'] | Should -Be 'https://contoso.sharepoint.com/sites/x'
        $env['DSA_LIST_NAME'] | Should -Be 'Eventos de seguridad'
        $env['DSA_X'] | Should -Be 'a'
        $env.ContainsKey('SIN_IGUAL') | Should -BeFalse
    }
    It 'conserva los signos = dentro del valor' {
        (ConvertFrom-DsaDotEnv -Lines @('K=a=b=c'))['K'] | Should -Be 'a=b=c'
    }
    It 'acepta una entrada vacía' {
        (ConvertFrom-DsaDotEnv -Lines @()).Count | Should -Be 0
    }
}

Describe 'Resolve-DsaSetting' {
    It 'da prioridad al parámetro, luego al entorno, luego al .env y al final al valor por defecto' {
        $dot = @{ K = 'dotenv' }
        $proc = @{ K = 'proceso' }
        Resolve-DsaSetting -Explicit 'param' -Name K -DotEnv $dot -ProcessEnv $proc | Should -Be 'param'
        Resolve-DsaSetting -Explicit '' -Name K -DotEnv $dot -ProcessEnv $proc | Should -Be 'proceso'
        Resolve-DsaSetting -Explicit $null -Name K -DotEnv $dot -ProcessEnv @{ K = '' } | Should -Be 'dotenv'
        Resolve-DsaSetting -Explicit $null -Name K -DotEnv @{} -ProcessEnv @{} -Default 'def' | Should -Be 'def'
        Resolve-DsaSetting -Explicit $null -Name K -DotEnv @{} -ProcessEnv @{} | Should -BeNullOrEmpty
    }
}

Describe 'ConvertTo-DsaSitePath y Get-DsaControlSiteUrl' {
    It 'convierte la URL del sitio a la ruta de Graph' {
        ConvertTo-DsaSitePath -SiteUrl 'https://contoso.sharepoint.com/sites/x' | Should -Be 'contoso.sharepoint.com:/sites/x'
        ConvertTo-DsaSitePath -SiteUrl 'https://contoso.sharepoint.com/sites/x/' | Should -Be 'contoso.sharepoint.com:/sites/x'
        ConvertTo-DsaSitePath -SiteUrl 'https://contoso.sharepoint.com/sites/DSA%20Demo' | Should -Be 'contoso.sharepoint.com:/sites/DSA Demo'
        ConvertTo-DsaSitePath -SiteUrl 'https://contoso.sharepoint.com' | Should -Be 'contoso.sharepoint.com'
    }
    It 'rechaza URL relativas o sin https' {
        { ConvertTo-DsaSitePath -SiteUrl 'http://contoso.sharepoint.com/sites/x' } | Should -Throw
        { ConvertTo-DsaSitePath -SiteUrl '/sites/x' } | Should -Throw
    }
    It 'deriva DSA-Control en el mismo host' {
        Get-DsaControlSiteUrl -SiteUrl 'https://contoso.sharepoint.com/sites/x' | Should -Be 'https://contoso.sharepoint.com/sites/DSA-Control'
    }
}

Describe 'Get-DsaMissingScopes' {
    It 'compara sin distinguir mayúsculas' {
        Get-DsaMissingScopes -Granted @('sites.manage.all', 'User.Read') -Required @('Sites.Manage.All', 'Files.ReadWrite.All') | Should -Be @('Files.ReadWrite.All')
        (Get-DsaMissingScopes -Granted $null -Required @('Sites.Read.All')).Count | Should -Be 1
    }
}

Describe 'Invoke-DsaGraphPaged' {
    It 'sigue @odata.nextLink hasta la última página' {
        $pages = @{
            'p1' = @{ value = @(@{ id = 1 }, @{ id = 2 }); '@odata.nextLink' = 'p2' }
            'p2' = @{ value = @(@{ id = 3 }) }
        }
        $items = Invoke-DsaGraphPaged -Uri 'p1' -Invoker { param($u) $pages[$u] }.GetNewClosure()
        @($items).Count | Should -Be 3
        $items[2].id | Should -Be 3
    }
    It 'devuelve una colección vacía si no hay valores' {
        $items = Invoke-DsaGraphPaged -Uri 'x' -Invoker { param($u) @{ value = @() } }
        @($items).Count | Should -Be 0
    }
    It 'corta si la paginación no termina' {
        { Invoke-DsaGraphPaged -Uri 'x' -MaxPages 3 -Invoker { param($u) @{ value = @(); '@odata.nextLink' = 'x' } } } | Should -Throw
    }
}

Describe 'Assert-DsaColumnContract' {
    It 'acepta columnas.json con sus 24 columnas' {
        $script:Columns.Count | Should -Be 24
    }
    It 'rechaza un tipo que no existe en columnDefinition' {
        { Assert-DsaColumnContract -Contract ([pscustomobject]@{ columns = @([pscustomobject]@{ name = 'X'; type = 'texto' }) }) } | Should -Throw '*Tipo no admitido*'
    }
    It 'rechaza una columna única sin índice' {
        { Assert-DsaColumnContract -Contract ([pscustomobject]@{ columns = @([pscustomobject]@{ name = 'X'; type = 'text'; unique = $true }) }) } | Should -Throw '*indexada*'
    }
    It 'rechaza nombres repetidos y elecciones vacías' {
        { Assert-DsaColumnContract -Contract ([pscustomobject]@{ columns = @([pscustomobject]@{ name = 'X'; type = 'text' }, [pscustomobject]@{ name = 'X'; type = 'text' }) }) } | Should -Throw '*repetida*'
        { Assert-DsaColumnContract -Contract ([pscustomobject]@{ columns = @([pscustomobject]@{ name = 'X'; type = 'choice'; choices = @() }) }) } | Should -Throw '*valores*'
    }
}

Describe 'New-DsaColumnBody' {
    BeforeAll {
        function Get-Col([string] $Name) { $script:Columns | Where-Object { $_.name -ceq $Name } }
    }
    It 'EventId es texto, obligatorio, único e indexado' {
        $body = New-DsaColumnBody -Column (Get-Col 'EventId')
        $body.name | Should -Be 'EventId'
        $body.required | Should -BeTrue
        $body.enforceUniqueValues | Should -BeTrue
        $body.indexed | Should -BeTrue
        $body.text.allowMultipleLines | Should -BeFalse
    }
    It 'Estado es elección con los seis estados y valor por defecto Nuevo' {
        $body = New-DsaColumnBody -Column (Get-Col 'Estado')
        $body.choice.choices | Should -Be @('Nuevo', 'Pendiente de decisión', 'Atendido', 'Escalado', 'Falsa alarma', 'Sin respuesta')
        $body.choice.allowTextEntry | Should -BeFalse
        $body.defaultValue.value | Should -Be 'Nuevo'
    }
    It 'Repeticiones es número entero con mínimo 1' {
        $body = New-DsaColumnBody -Column (Get-Col 'Repeticiones')
        $body.number.decimalPlaces | Should -Be 'none'
        $body.number.minimum | Should -Be 1
    }
    It 'los textos multilínea usan allowMultipleLines' {
        (New-DsaColumnBody -Column (Get-Col 'ResumenAgente')).text.allowMultipleLines | Should -BeTrue
        (New-DsaColumnBody -Column (Get-Col 'Observacion')).required | Should -BeFalse
    }
    It 'EsPrueba es booleano, fechas con hora y DecididoPor una sola persona' {
        (New-DsaColumnBody -Column (Get-Col 'EsPrueba')).Contains('boolean') | Should -BeTrue
        (New-DsaColumnBody -Column (Get-Col 'FechaDecision')).dateTime.format | Should -Be 'dateTime'
        $person = (New-DsaColumnBody -Column (Get-Col 'DecididoPor')).personOrGroup
        $person.allowMultipleSelection | Should -BeFalse
        $person.chooseFromType | Should -Be 'peopleOnly'
    }
    It 'cada columna del contrato lleva exactamente una faceta de tipo, la del contrato' {
        $facets = @('text', 'choice', 'number', 'dateTime', 'boolean', 'personOrGroup')
        foreach ($column in $script:Columns) {
            $body = New-DsaColumnBody -Column $column
            $present = @($facets | Where-Object { $body.Contains($_) })
            $present | Should -Be @($column.type) -Because $column.name
        }
    }
    It 'conserva las tildes del nombre visible en el JSON' {
        $json = New-DsaColumnBody -Column (Get-Col 'SeveridadRaw') | ConvertTo-Json -Depth 10 -EscapeHandling EscapeNonAscii
        ($json | ConvertFrom-Json).choice.choices | Should -Contain 'Crítica'
    }
}

Describe 'Compare-DsaColumns' {
    It 'en una lista recién creada (solo Title) crea todas las columnas menos Title' {
        $existing = @(@{ id = 't'; name = 'Title'; displayName = 'Title'; required = $true; text = @{ allowMultipleLines = $false } })
        $plan = Compare-DsaColumns -Contract $script:Columns -Existing $existing
        @($plan | Where-Object Action -EQ 'Create').Count | Should -Be 23
        ($plan | Where-Object Name -CEQ 'Title').Action | Should -Be 'Ok'
    }
    It 'CA-07.2: la segunda ejecución no crea ni cambia nada' {
        $plan = Compare-DsaColumns -Contract $script:Columns -Existing (New-FakeExisting -Columns $script:Columns)
        @($plan | Where-Object Action -NE 'Ok').Count | Should -Be 0
        $plan.Count | Should -Be 24
    }
    It 'informa como conflicto que falte la columna integrada Title' {
        $plan = Compare-DsaColumns -Contract $script:Columns -Existing @()
        ($plan | Where-Object Name -CEQ 'Title').Action | Should -Be 'Conflict'
    }
    It 'completa la unicidad y el índice de EventId si faltan' {
        $existing = New-FakeExisting -Columns $script:Columns
        $event = $existing | Where-Object { $_.name -ceq 'EventId' }
        $event.enforceUniqueValues = $false
        $event.indexed = $false
        $step = Compare-DsaColumns -Contract $script:Columns -Existing $existing | Where-Object Name -CEQ 'EventId'
        $step.Action | Should -Be 'Update'
        $step.Id | Should -Be 'id-EventId'
        $step.Patch.indexed | Should -BeTrue
        $step.Patch.enforceUniqueValues | Should -BeTrue
    }
    It 'agrega las elecciones que faltan sin quitar las que ya existen' {
        $existing = New-FakeExisting -Columns $script:Columns
        ($existing | Where-Object { $_.name -ceq 'Estado' }).choice = @{ choices = @('Nuevo', 'Manual') }
        $step = Compare-DsaColumns -Contract $script:Columns -Existing $existing | Where-Object Name -CEQ 'Estado'
        $step.Action | Should -Be 'Update'
        $step.Patch.choice.choices[0..1] | Should -Be @('Nuevo', 'Manual')
        $step.Patch.choice.choices | Should -Contain 'Sin respuesta'
        $step.Patch.choice.choices.Count | Should -Be 7
    }
    It 'corrige obligatoriedad, nombre visible y valor por defecto' {
        $existing = New-FakeExisting -Columns $script:Columns
        $estado = $existing | Where-Object { $_.name -ceq 'Estado' }
        $estado.required = $false
        $estado.displayName = 'estado'
        $estado.defaultValue = @{ value = 'Atendido' }
        $step = Compare-DsaColumns -Contract $script:Columns -Existing $existing | Where-Object Name -CEQ 'Estado'
        $step.Patch.required | Should -BeTrue
        $step.Patch.displayName | Should -Be 'Estado'
        $step.Patch.defaultValue.value | Should -Be 'Nuevo'
    }
    It 'no cambia el tipo de una columna: lo marca como conflicto' {
        $existing = @(New-FakeExisting -Columns $script:Columns | Where-Object { $_.name -cne 'Repeticiones' })
        $existing += @{ id = 'r'; name = 'Repeticiones'; displayName = 'Repeticiones'; required = $true; text = @{ allowMultipleLines = $false } }
        $step = Compare-DsaColumns -Contract $script:Columns -Existing $existing | Where-Object Name -CEQ 'Repeticiones'
        $step.Action | Should -Be 'Conflict'
        $step.Detail | Should -BeLike "*'text'*'number'*"
    }
    It 'marca como conflicto un texto de una línea que el contrato pide multilínea' {
        $existing = New-FakeExisting -Columns $script:Columns
        ($existing | Where-Object { $_.name -ceq 'Observacion' }).text = @{ allowMultipleLines = $false }
        (Compare-DsaColumns -Contract $script:Columns -Existing $existing | Where-Object Name -CEQ 'Observacion').Action | Should -Be 'Conflict'
    }
    It 'no crea una columna si su nombre visible ya lo usa otra con otro nombre interno' {
        $existing = @(@{ id = 't'; name = 'Title'; displayName = 'Title'; required = $true; text = @{} },
            @{ id = 'z'; name = 'Zona_x0020_1'; displayName = 'Zona'; required = $false; text = @{ allowMultipleLines = $false } })
        $step = Compare-DsaColumns -Contract $script:Columns -Existing $existing | Where-Object Name -CEQ 'Zona'
        $step.Action | Should -Be 'Conflict'
        $step.Detail | Should -BeLike '*Zona_x0020_1*'
    }
    It 'ignora las columnas de la lista que no están en el contrato' {
        $plan = Compare-DsaColumns -Contract $script:Columns -Existing (New-FakeExisting -Columns $script:Columns)
        $plan.Name | Should -Not -Contain 'Created'
    }
}

Describe 'Get-DsaLibraryColumnContract' {
    It 'define TipoEvento con las elecciones de la lista, Version y HashFuente' {
        $lib = Get-DsaLibraryColumnContract -ListContract $script:Columns
        $lib.name | Should -Be @('TipoEvento', 'VersionProtocolo', 'HashFuente')
        ($lib | Where-Object name -CEQ 'TipoEvento').choices | Should -Be @('movimiento_zona_restringida', 'puerta_forzada', 'acceso_denegado_repetido')
        ($lib | Where-Object name -CEQ 'VersionProtocolo').type | Should -Be 'text'
        { Assert-DsaColumnContract -Contract ([pscustomobject]@{ columns = $lib }) } | Should -Not -Throw
    }
    It 'evita el nombre visible Version de la columna integrada' {
        ((Get-DsaLibraryColumnContract -ListContract $script:Columns) | Where-Object name -CEQ 'VersionProtocolo').displayName | Should -Not -Be 'Version'
    }
}

Describe 'Protocolos' {
    BeforeAll {
        $script:Types = @('movimiento_zona_restringida', 'puerta_forzada', 'acceso_denegado_repetido')
    }
    It 'lee tipo y versión de cada protocolo real de protocols/' {
        $files = Get-ChildItem (Join-Path $script:Root 'protocols') -Filter '*.md'
        $files.Count | Should -Be 3
        foreach ($file in $files) {
            $meta = Get-DsaProtocolMetadata -FileStem $file.BaseName -Markdown (Get-Content $file.FullName -Raw -Encoding utf8) -AllowedTypes $script:Types
            $meta.TipoEvento | Should -Be $file.BaseName
            $meta.Version | Should -Match '^\d+(\.\d+)*$'
            $meta.FileName | Should -Be "$($file.BaseName).docx"
        }
    }
    It 'rechaza un protocolo sin tipo de evento o sin versión' {
        { Get-DsaProtocolMetadata -FileStem 'otro' -Markdown '**Versión:** 1.0' -AllowedTypes $script:Types } | Should -Throw '*TipoEvento*'
        { Get-DsaProtocolMetadata -FileStem 'puerta_forzada' -Markdown '# Sin versión' -AllowedTypes $script:Types } | Should -Throw '*Versión*'
    }
    It 'el hash de la fuente es estable y cambia con el Markdown o con el conversor' {
        $md = [Text.Encoding]::UTF8.GetBytes('# Protocolo')
        $builder = [Text.Encoding]::UTF8.GetBytes('print(1)')
        $a = Get-DsaProtocolHash -MarkdownBytes $md -BuilderBytes $builder
        $a | Should -Match '^[0-9a-f]{64}$'
        Get-DsaProtocolHash -MarkdownBytes $md -BuilderBytes $builder | Should -Be $a
        Get-DsaProtocolHash -MarkdownBytes ([Text.Encoding]::UTF8.GetBytes('# Protocolo 2')) -BuilderBytes $builder | Should -Not -Be $a
        Get-DsaProtocolHash -MarkdownBytes $md -BuilderBytes ([Text.Encoding]::UTF8.GetBytes('print(2)')) | Should -Not -Be $a
    }
    It 'planifica subir, reemplazar, omitir e informar sobrantes' {
        $local = @(
            [pscustomobject]@{ FileName = 'a.docx'; Hash = 'h1' }
            [pscustomobject]@{ FileName = 'b.docx'; Hash = 'h2' }
            [pscustomobject]@{ FileName = 'c.docx'; Hash = 'h3' }
            [pscustomobject]@{ FileName = 'd.docx'; Hash = 'h4' }
        )
        $remote = @(
            [pscustomobject]@{ FileName = 'B.docx'; Hash = 'H2'; ListItemId = '2' }
            [pscustomobject]@{ FileName = 'c.docx'; Hash = 'viejo'; ListItemId = '3' }
            [pscustomobject]@{ FileName = 'd.docx'; Hash = ''; ListItemId = '4' }
            [pscustomobject]@{ FileName = 'manual.docx'; Hash = ''; ListItemId = '9' }
        )
        $plan = Get-DsaProtocolPlan -Local $local -Remote $remote
        ($plan | Where-Object FileName -EQ 'a.docx').Action | Should -Be 'Upload'
        ($plan | Where-Object FileName -EQ 'b.docx').Action | Should -Be 'Skip'
        ($plan | Where-Object FileName -EQ 'c.docx').Action | Should -Be 'Replace'
        ($plan | Where-Object FileName -EQ 'd.docx').Action | Should -Be 'Replace'
        ($plan | Where-Object FileName -EQ 'manual.docx').Action | Should -Be 'Extra'
    }
    It 'CA-07.2: con los mismos hashes no sube nada' {
        $local = @([pscustomobject]@{ FileName = 'a.docx'; Hash = 'h1' })
        $plan = Get-DsaProtocolPlan -Local $local -Remote @([pscustomobject]@{ FileName = 'a.docx'; Hash = 'h1'; ListItemId = '1' })
        @($plan | Where-Object Action -In 'Upload', 'Replace').Count | Should -Be 0
    }
    It 'convierte los elementos de la biblioteca de Graph' {
        $items = @(
            @{ id = '1'; fields = @{ FileLeafRef = 'puerta_forzada.docx'; HashFuente = 'abc' } }
            @{ id = '2'; fields = @{ FileLeafRef = 'otro.docx' } }
            @{ id = '3'; fields = @{} }
        )
        $remote = ConvertFrom-DsaLibraryItems -Items $items
        $remote.Count | Should -Be 2
        $remote[0].Hash | Should -Be 'abc'
        $remote[1].Hash | Should -Be ''
        $remote[0].ListItemId | Should -Be '1'
    }
}

Describe 'Test-DsaControlSiteEmpty' {
    It 'ignora la biblioteca de páginas y las listas ocultas' {
        $lists = @(
            @{ displayName = 'Site Pages'; template = 'webPageLibrary'; hidden = $false; itemCount = 1 }
            @{ displayName = 'Oculta'; template = 'genericList'; hidden = $true; itemCount = 5 }
            @{ displayName = 'Documents'; template = 'documentLibrary'; hidden = $false; itemCount = 0 }
        )
        (Test-DsaControlSiteEmpty -Lists $lists).IsEmpty | Should -BeTrue
    }
    It 'informa qué listas tienen elementos' {
        $lists = @(@{ displayName = 'Documents'; template = 'documentLibrary'; hidden = $false; itemCount = 2 })
        $result = Test-DsaControlSiteEmpty -Lists $lists
        $result.IsEmpty | Should -BeFalse
        $result.NonEmpty | Should -Be @('Documents')
    }
    It 'un sitio sin listas está vacío' {
        (Test-DsaControlSiteEmpty -Lists @()).IsEmpty | Should -BeTrue
    }
}

Describe 'Get-DsaHttpStatus y Format-DsaLine' {
    It 'lee el código de la respuesta o del mensaje' {
        Get-DsaHttpStatus ([pscustomobject]@{ Response = [pscustomobject]@{ StatusCode = 404 }; Message = '' }) | Should -Be 404
        Get-DsaHttpStatus ([pscustomobject]@{ Response = $null; Message = 'Response status code does not indicate success: NotFound (Not Found).' }) | Should -Be 404
        Get-DsaHttpStatus ([pscustomobject]@{ Response = $null; Message = 'otro' }) | Should -BeNullOrEmpty
    }
    It 'da texto y color según el estado' {
        $line = Format-DsaLine -Status Created -Message 'Lista'
        $line.Text | Should -BeLike '`[creado`]*Lista'
        $line.Color | Should -Be 'Green'
        (Format-DsaLine -Status Error -Message 'x').Color | Should -Be 'Red'
        (Format-DsaLine -Status Exists -Message 'x').Text | Should -BeLike '*ya existía*'
    }
}

Describe 'provision.ps1' {
    It 'no tiene errores de sintaxis' {
        $errors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $script:Root 'sharepoint' 'provision.ps1'), [ref]$null, [ref]$errors)
        $errors.Count | Should -Be 0
    }
    It 'pide solo los ámbitos delegados mínimos y no guarda credenciales' {
        $text = Get-Content (Join-Path $script:Root 'sharepoint' 'provision.ps1') -Raw
        $text | Should -Match "\`$RequiredScopes = @\('Sites.Manage.All', 'Files.ReadWrite.All'\)"
        $text | Should -Not -Match 'Sites\.FullControl\.All\s*['']'
        $text | Should -Not -Match '-ClientSecret|-CertificateThumbprint|ClientSecretCredential'
        $text | Should -Not -Match 'New-MgSite\b'
    }
}
