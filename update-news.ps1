# ============================================================
#  Hoy en Pamplona - actualizador diario de noticias
#  Genera index.html a partir de:
#    - RSS de Diario de Navarra
#    - API JSON de RTVE (para la sección Mundial)
#
#  Uso:
#    powershell -NoProfile -ExecutionPolicy Bypass -File update-news.ps1
#    powershell ... -File update-news.ps1 -DryRun
#    powershell ... -File update-news.ps1 -NoOpen   (no abre el navegador; lo usa GitHub Actions)
#    powershell ... -File update-news.ps1 -Now "2026-10-20 07:30"
# ============================================================

[CmdletBinding()]
param(
    [string]$Root = "",
    [int]$PerCategory = 11,
    [datetime]$Now = (Get-Date),
    [switch]$DryRun,
    [switch]$NoOpen
)

if ([string]::IsNullOrWhiteSpace($Root)) {
    $Root = $PSScriptRoot
    if ([string]::IsNullOrWhiteSpace($Root)) {
        $Root = Split-Path -Parent $MyInvocation.MyCommand.Path
    }
}

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$script:Headers = @{
    "User-Agent"      = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/155.0.0.0 Safari/537.36"
    "Accept-Language" = "es-ES,es;q=0.9"
}

# ============================================================
# Configuración de fuentes
# ============================================================
# Nota: las URLs de RSS de abajo son marcadores de posición.
# Antes de usarlas, verifica en el sitio correspondiente la dirección
# real de su feed RSS (suele estar en el pie de página o en /rss).
# Si un sitio no tiene RSS público, puedes dejarlo con $null y se omitirá.
$script:Sources = @(
    @{
        Name    = "Diario de Navarra"
        Type    = "rss"
        Url     = "https://www.diariodenavarra.es/rss/contenidos.xml"
        Enabled = $true
    },
    @{
        Name    = "RTVE"
        Type    = "rtve"
        Url     = "https://www.rtve.es/api/noticias.json"
        Enabled = $true
    },
    @{
        Name    = "El Mundo"
        Type    = "rss"
        # TODO: sustituir por la URL real del RSS de El Mundo
        Url     = "https://e00-elmundo.uecdn.es/rss/portada.xml"
        Enabled = $true   # cámbialo a $true cuando la URL esté verificada
    },
    @{
        Name    = "El Pais"
        Type    = "rss"
        # TODO: sustituir por la URL real del RSS de El País
        Url     = "https://feeds.elpais.com/mrss-s/pages/ep/site/elpais.com/section/ultimas-noticias/portada"
        Enabled = $true
    },
    @{
        Name    = "Noticias de Navarra"
        Type    = "rss"
        # TODO: sustituir por la URL real del RSS de Noticias de Navarra
        Url     = "https://www.noticiasdenavarra.com/rss/section/20001"
        Enabled = $true
    }
)

$script:EsES = [Globalization.CultureInfo]::GetCultureInfo("es-ES")
$script:Invariant = [Globalization.CultureInfo]::InvariantCulture
$script:Months = @("enero", "febrero", "marzo", "abril", "mayo", "junio", "julio", "agosto", "septiembre", "octubre", "noviembre", "diciembre")
$script:MonthsShort = @("ene", "feb", "mar", "abr", "may", "jun", "jul", "ago", "sep", "oct", "nov", "dic")

function Write-Log {
    param([string]$Message)
    $line = "[" + (Get-Date).ToString("HH:mm:ss") + "] " + $Message
    Write-Host $line
}

function Get-UrlText {
    param([string]$Url)
    $response = Invoke-WebRequest -Uri $Url -UseBasicParsing -Headers $script:Headers -TimeoutSec 45
    $stream = $response.RawContentStream
    if ($null -eq $stream) { return [string]$response.Content }
    $stream.Position = 0
    $bytes = $stream.ToArray()
    return [Text.Encoding]::UTF8.GetString($bytes)
}

function Clean-Text {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return "" }
    $value = [Net.WebUtility]::HtmlDecode($Text)
    $value = $value -replace "(?s)<!\[CDATA\[", ""
    $value = $value -replace "(?s)\]\]>", ""
    $value = [regex]::Replace($value, "(?is)<script.*?</script>", " ")
    $value = [regex]::Replace($value, "(?is)<style.*?</style>", " ")
    $value = [regex]::Replace($value, "(?s)<[^>]+>", " ")
    $value = [Net.WebUtility]::HtmlDecode($value)
    $value = [regex]::Replace($value, "\s+", " ")
    return $value.Trim()
}

function ConvertTo-HtmlText {
    param([string]$Text)
    return [Net.WebUtility]::HtmlEncode($Text)
}

function Get-ShortSummary {
    param([string]$Text, [int]$MaxLength = 190)
    $clean = Clean-Text $Text
    if ($clean.Length -le $MaxLength) { return $clean }
    $cut = $clean.Substring(0, $MaxLength)
    $sentence = $cut.LastIndexOf(". ", [StringComparison]::Ordinal)
    if ($sentence -ge 90) { return $clean.Substring(0, $sentence + 1).Trim() }
    $space = $cut.LastIndexOf(" ", [StringComparison]::Ordinal)
    if ($space -gt 60) { $cut = $cut.Substring(0, $space) }
    return $cut.TrimEnd(",", ";", ":", " ", ".") + " ..."
}

function Normalize-Url {
    param([string]$Url)
    $value = [Net.WebUtility]::HtmlDecode($Url)
    if ($value.StartsWith("//")) { $value = "https:" + $value }
    elseif ($value.StartsWith("/")) { $value = "https://www.diariodenavarra.es" + $value }
    $value = ($value -split "\?")[0]
    $value = ($value -split "#")[0]
    return $value.Trim()
}

function Parse-DnDate {
    param([string]$Value)
    try {
        return [datetimeoffset]::Parse($Value, $script:Invariant)
    } catch {
        return $null
    }
}

function Parse-RtveDate {
    param([string]$Value)
    try {
        $dt = [datetime]::ParseExact($Value, "dd-MM-yyyy HH:mm:ss", $script:Invariant, [Globalization.DateTimeStyles]::AssumeLocal)
        return [datetimeoffset]$dt
    } catch {
        return $null
    }
}

function Get-MonthShort {
    param([int]$Month)
    return $script:MonthsShort[$Month - 1]
}

function Format-TimeLabel {
    param([datetimeoffset]$Published, [datetimeoffset]$Reference)
    if ($Published.Date -eq $Reference.Date) {
        return $Published.ToString("HH:mm") + " h"
    }
    return ("" + $Published.Day + " " + (Get-MonthShort $Published.Month))
}

function Format-IsoDate {
    param([datetimeoffset]$Value)
    return $Value.ToString("yyyy-MM-ddTHH:mm:sszzz")
}

function Get-Topic {
    param([string]$Title, [string]$Summary, [string]$Fallback)

    $text = (" " + $Title + " " + $Summary).ToLowerInvariant()
    $rules = @(
        @("osasuna|arrasate|budimir|el sadar", "Osasuna"),
        @("patinete|bicicleta|bici |movilidad|tráfico|trafico|aparcamiento|zona azul|rochapea", "Movilidad"),
        @("alquiler|vivienda|hipoteca|pisos|piso |inmobiliar", "Vivienda"),
        @("reforma laboral|contrato|afiliad|empleo|paro|trabajadores", "Empleo"),
        @("elecciones|senado|vox|feijóo|feijoo|sánchez|sanchez|ayuso|mónica|monica|frente amplio|psoe|pp |campaña", "Elecciones"),
        @("papa|león xiv|leon xiv|iglesia|sacerdote|vaticano", "Iglesia"),
        @("ucrania|zelenski|putin|trump|xi jinping|guerra", "Ucrania"),
        @("francia|macron|toques de queda|disturbios|saqueos", "Francia"),
        @("canadá|canada|alberta|referéndum|referendum", "Canadá"),
        @("libia|gadafi", "Libia"),
        @("generación z|generacion z|juventud europea|protestas", "Europa"),
        @("cambio de hora|calendario|horario de invierno", "Calendario"),
        @("dana|aemet|lluvia|temperatura|tiempo|meteorolog", "Tiempo"),
        @("suceso|detenid|herid|accidente|fallecid|muerte|incendio", "Sucesos"),
        @("cultura|cine|música|musica|teatro|libro|exposici|concierto", "Cultura"),
        @("salud|médic|medic|hospital|cáncer|cancer|colesterol", "Salud"),
        @("economía|economia|empresa|mercado|precios|euro|industria", "Economia"),
        @("plaza|urbanismo|barrio|centro de día|centro de dia|ayuntamiento", "Pamplona")
    )

    foreach ($rule in $rules) {
        if ($text -match $rule[0]) { return $rule[1] }
    }
    return $Fallback
}

function Get-NodeText {
    param($Node, [string]$Name)
    $child = $Node.SelectSingleNode($Name)
    if ($null -eq $child) { return "" }
    return [string]$child.InnerText
}

function Get-DnItems {
    $url = "https://www.diariodenavarra.es/rss/contenidos.xml"
    Write-Log "Descargando RSS de Diario de Navarra..."
    $text = Get-UrlText $url

    $xml = New-Object System.Xml.XmlDocument
    $xml.LoadXml($text)
    $nodes = $xml.SelectNodes("/rss/channel/item")
    Write-Log ("Items en el RSS: " + $nodes.Count)

    $items = New-Object System.Collections.Generic.List[object]
    foreach ($node in $nodes) {
        $title = Clean-Text (Get-NodeText $node "title")
        $link = Normalize-Url (Get-NodeText $node "link")
        $summary = Clean-Text (Get-NodeText $node "description")
        $category = Clean-Text (Get-NodeText $node "category")
        $published = Parse-DnDate (Get-NodeText $node "pubDate")
        if ([string]::IsNullOrWhiteSpace($title) -or [string]::IsNullOrWhiteSpace($link) -or $null -eq $published) { continue }

        $items.Add([PSCustomObject]@{
            Title     = $title
            Url       = $link
            Summary   = $summary
            Published = $published
            Source    = "Diario de Navarra"
            Category  = $category
            Topic     = Get-Topic $title $summary "Actualidad"
            Key       = $link
        })
    }
    Write-Log ("Items válidos DN: " + $items.Count)
    if ($items.Count -gt 0) { Write-Log ("Primero: " + $items[0].Published.ToString("o") + " | " + $items[0].Title) }
    return $items
}

function Get-GenericRssItems {
    param(
        [string]$SourceName,
        [string]$Url
    )
    if ([string]::IsNullOrWhiteSpace($Url)) {
        Write-Log ("Fuente " + $SourceName + " sin URL configurada; se omite.")
        return @()
    }
    try {
        Write-Log ("Descargando RSS de " + $SourceName + "...")
        $text = Get-UrlText $Url
        $xml = New-Object System.Xml.XmlDocument
        $xml.LoadXml($text)
        $nodes = $xml.SelectNodes("/rss/channel/item")
        if ($null -eq $nodes -or $nodes.Count -eq 0) {
            $nodes = $xml.SelectNodes("//item")
        }
        Write-Log ("  Items: " + $nodes.Count)

        $items = New-Object System.Collections.Generic.List[object]
        foreach ($node in $nodes) {
            $title = Clean-Text (Get-NodeText $node "title")
            $link = Normalize-Url (Get-NodeText $node "link")
            $summary = Clean-Text (Get-NodeText $node "description")
            $published = Parse-DnDate (Get-NodeText $node "pubDate")
            if ([string]::IsNullOrWhiteSpace($title) -or [string]::IsNullOrWhiteSpace($link) -or $null -eq $published) { continue }

            $items.Add([PSCustomObject]@{
                Title     = $title
                Url       = $link
                Summary   = $summary
                Published = $published
                Source    = $SourceName
                Category  = ""
                Topic     = Get-Topic $title $summary "Actualidad"
                Key       = $link
            })
        }
        return $items
    } catch {
        Write-Log ("Aviso: fallo al leer " + $SourceName + ": " + $_.Exception.Message)
        return @()
    }
}

function Get-SectionOrder {
    param([string]$Url, [string]$Prefix, [string]$Heading, [datetimeoffset]$Reference)

    try {
        $html = Get-UrlText $Url
    } catch {
        Write-Log ("Aviso: no se pudo leer " + $Url + ": " + $_.Exception.Message)
        return @()
    }

    # Los enlaces del bloque "Es noticia" están antes del h1 de la sección.
    # Empezamos a leer después del titular para quedarnos con las tarjetas.
    $startAt = 0
    $headingMatch = [regex]::Match($html, "(?is)<h1[^>]*>.*?" + [regex]::Escape($Heading) +     ".*?</h1>")
    if (-not $headingMatch.Success) {
        Write-Log ("Aviso: no se encontró el <h1> de " + $Heading + "; se omite el orden editorial.")
        return @()
    }
    $startAt = $headingMatch.Index + $headingMatch.Length
    $segment = $html.Substring($startAt)

    $ordered = New-Object System.Collections.Generic.List[string]
    $seen = New-Object "System.Collections.Generic.HashSet[string]"

    foreach ($match in [regex]::Matches($segment, 'href="([^"]+)"')) {
        $raw = [Net.WebUtility]::HtmlDecode($match.Groups[1].Value)
        if ($raw -notmatch "/noticias/") { continue }
        $link = Normalize-Url $raw
        if (-not $link.Contains($Prefix)) { continue }

        $dateMatch = [regex]::Match($link, "/(\d{4})/(\d{2})/(\d{2})/")
        if (-not $dateMatch.Success) { continue }
        try {
            $linkDate = New-Object datetime ([int]$dateMatch.Groups[1].Value), ([int]$dateMatch.Groups[2].Value), ([int]$dateMatch.Groups[3].Value)
        } catch {
            continue
        }
        # Solo el orden editorial de hoy; el resto se rellena por fecha.
        if ($linkDate -ne $Reference.Date) { continue }
        if ($seen.Add($link)) { $ordered.Add($link) }
    }

    Write-Log ("Orden editorial " + $Heading + ": " + $ordered.Count + " enlaces de hoy")
    return $ordered
}

function Select-ForCategory {
    param($Candidates, $OrderedUrls, [int]$Count)

    if ($null -eq $Candidates) { $Candidates = @() }
    if ($null -eq $OrderedUrls) { $OrderedUrls = @() }
    if ($Count -le 0) { return @() }

    $selected = New-Object System.Collections.Generic.List[object]
    $seen = New-Object "System.Collections.Generic.HashSet[string]"

    foreach ($url in $OrderedUrls) {
        if ($selected.Count -ge $Count) { break }
        $candidate = $Candidates | Where-Object { $_.Url -eq $url } | Select-Object -First 1
        if ($null -ne $candidate -and $seen.Add($candidate.Url)) { $selected.Add($candidate) }
    }

    foreach ($candidate in ($Candidates | Sort-Object Published -Descending)) {
        if ($selected.Count -ge $Count) { break }
        if ($seen.Add($candidate.Url)) { $selected.Add($candidate) }
    }

    return $selected
}

function Get-TitleKey {
    param([string]$Title)
    return ($Title.ToLowerInvariant() -replace "[^\p{L}\p{N}]", "")
}

function Test-DuplicateTitle {
    param([string]$Title, $Selected)
    $key = Get-TitleKey $Title
    if ($key.Length -lt 12) { return $false }
    foreach ($item in $Selected) {
        $other = Get-TitleKey $item.Title
        if ($key -eq $other) { return $true }
        if ($key.Length -gt 28 -and $other.Length -gt 28) {
            if ($key.Contains($other.Substring(0, 28)) -or $other.Contains($key.Substring(0, 28))) { return $true }
        }
    }
    return $false
}

function Get-RtveWorld {
    param([datetimeoffset]$Reference, [int]$Hours = 36)

    $start = $Reference.AddHours(-$Hours)
    $items = New-Object System.Collections.Generic.List[object]
    $seen = New-Object "System.Collections.Generic.HashSet[string]"

    for ($page = 1; $page -le 5; $page++) {
        $url = "https://www.rtve.es/api/noticias.json?size=50&page=" + $page
        try {
            $json = Get-UrlText $url | ConvertFrom-Json
        } catch {
            Write-Log ("Aviso: fallo RTVE página " + $page + ": " + $_.Exception.Message)
            break
        }

        foreach ($item in $json.page.items) {
            $category = [string]$item.mainCategory
            if ($category -notmatch "^Noticias/Mundo" -and $category -notmatch "Guerra en Ucrania") { continue }

            $published = Parse-RtveDate ([string]$item.publicationDate)
            if ($null -eq $published) { continue }
            if ($published -lt $start -or $published -gt $Reference.AddMinutes(10)) { continue }

            $link = Normalize-Url ([string]$item.htmlUrl)
            if ([string]::IsNullOrWhiteSpace($link) -or -not $seen.Add($link)) { continue }

            $summary = ""
            $bullets = [regex]::Matches([string]$item.summary, "(?is)<li[^>]*>(.*?)</li>")
            if ($bullets.Count -gt 0) {
                $parts = @()
                foreach ($bullet in $bullets) { $parts += (Clean-Text $bullet.Groups[1].Value) }
                $summary = ($parts | Select-Object -First 2) -join ". "
            } else {
                $summary = Clean-Text ([string]$item.summary)
            }

            $title = Clean-Text ([string]$item.title)
            $items.Add([PSCustomObject]@{
                Title     = $title
                Url       = $link
                Summary   = $summary
                Published = $published
                Source    = "RTVE"
                Category  = $category
                Topic     = Get-Topic $title $summary "Mundo"
                Key       = $link
            })
        }
    }

    Write-Log ("Candidatos RTVE Mundo (" + $Hours + " h): " + $items.Count)
    return $items | Sort-Object Published -Descending
}

function New-NewsBlock {
    param($Items, [datetimeoffset]$Reference)

    $builder = New-Object System.Text.StringBuilder

    if ($null -eq $Items -or $Items.Count -eq 0) {
        return "        <p class=""panel-intro"">No se han podido cargar las noticias de esta categoría.</p>"
    }

    $lead = $Items[0]
    $leadUrl = ConvertTo-HtmlText $lead.Url
    $leadTitle = ConvertTo-HtmlText $lead.Title
    $leadSummary = ConvertTo-HtmlText (Get-ShortSummary $lead.Summary 210)
    $leadSource = ConvertTo-HtmlText $lead.Source
    $leadTopic = ConvertTo-HtmlText $lead.Topic
    $leadTime = ConvertTo-HtmlText (Format-TimeLabel $lead.Published $Reference)
    $leadIso = ConvertTo-HtmlText (Format-IsoDate $lead.Published)

    [void]$builder.AppendLine("        <article class=""lead"" data-source=""" + $leadSource + """>")
    [void]$builder.AppendLine("          <p class=""lead-label"">Lo mas importante</p>")
    [void]$builder.AppendLine("          <h3><a href=""" + $leadUrl + """ target=""_blank"" rel=""noopener"">" + $leadTitle + "</a></h3>")
    [void]$builder.AppendLine("          <p>" + $leadSummary + "</p>")
    [void]$builder.AppendLine("          <p class=""meta""><span class=""source"">" + $leadSource + "</span><span class=""dot""></span><time datetime=""" + $leadIso + """>" + $leadTime + "</time><span class=""dot""></span><span>" + $leadTopic + "</span></p>")
    [void]$builder.AppendLine("        </article>")
    [void]$builder.AppendLine("")
    [void]$builder.AppendLine("        <div class=""grid"">")

    for ($i = 1; $i -lt $Items.Count; $i++) {
        $item = $Items[$i]
        $url = ConvertTo-HtmlText $item.Url
        $title = ConvertTo-HtmlText $item.Title
        $summary = ConvertTo-HtmlText (Get-ShortSummary $item.Summary 175)
        $source = ConvertTo-HtmlText $item.Source
        $topic = ConvertTo-HtmlText $item.Topic
        $time = ConvertTo-HtmlText (Format-TimeLabel $item.Published $script:Reference)
        $iso = ConvertTo-HtmlText (Format-IsoDate $item.Published)

        [void]$builder.AppendLine("          <article class=""card"" data-source=""" + $source + """>")
        [void]$builder.AppendLine("            <p class=""eyebrow"">" + $topic + "</p>")
        [void]$builder.AppendLine("            <h3><a href=""" + $url + """ target=""_blank"" rel=""noopener"">" + $title + "</a></h3>")
        [void]$builder.AppendLine("            <p>" + $summary + "</p>")
        [void]$builder.AppendLine("            <p class=""meta""><span class=""source"">" + $source + "</span><span class=""dot""></span><time datetime=""" + $iso + """>" + $time + "</time></p>")
        [void]$builder.AppendLine("          </article>")
        [void]$builder.AppendLine("")
    }

    [void]$builder.AppendLine("        </div>")
    return $builder.ToString().TrimEnd()
}

function Set-MarkerBlock {
    param([string]$Html, [string]$Name, [string]$Block)
    $startMarker = "<!-- AUTO:" + $Name + ":START -->"
    $endMarker   = "<!-- AUTO:" + $Name + ":END -->"
    $start = $Html.IndexOf($startMarker, [StringComparison]::Ordinal)
    $end   = $Html.IndexOf($endMarker,   [StringComparison]::Ordinal)
    if ($start -lt 0 -or $end -lt 0 -or $end -lt $start) {
        throw ("No se encuentran los marcadores AUTO:" + $Name)
    }
    $block = $Block.TrimEnd("`r", "`n")
    $prefix = $Html.Substring(0, $start + $startMarker.Length)
    $suffix = $Html.Substring($end)
    return $prefix + "`r`n" + $block + "`r`n        " + $suffix
}

function Set-SimpleInner {
    param([string]$Html, [string]$Pattern, [string]$Value)
    return [regex]::Replace(
        $Html,
        $Pattern,
        { param($m) $m.Groups[1].Value + $Value + $m.Groups[2].Value },
        [Text.RegularExpressions.RegexOptions]::Singleline
    )
}

try {
    $nowDto = [datetimeoffset]$Now
    $script:Reference = $nowDto
    $dateLong = "" + $Now.Day + " de " + $script:Months[$Now.Month - 1] + " de " + $Now.Year
    $dayName = $Now.ToString("dddd", $script:EsES)
    $dayCap = $dayName.Substring(0, 1).ToUpperInvariant() + $dayName.Substring(1)
    $timeLabel = $Now.ToString("HH:mm")
    $dateMark = $Now.ToString("dd.MM")

    Write-Log ("Inicio de la edición: " + $dateLong + " " + $timeLabel + " (ventana 30 h)")

    $indexPath = Join-Path $Root "index.html"
    if (-not (Test-Path -LiteralPath $indexPath)) { throw ("No existe " + $indexPath) }
    $utf8NoBom = New-Object Text.UTF8Encoding($false)
    $bytes = [IO.File]::ReadAllBytes($indexPath)
    $html = [Text.Encoding]::UTF8.GetString($bytes)

    $dnItems = Get-DnItems

# Recopilar noticias de otras fuentes RSS configuradas
$allExtraItems = New-Object System.Collections.Generic.List[object]
foreach ($source in $script:Sources) {
    if (-not $source.Enabled) { continue }
    if ($source.Type -ne "rss") { continue }
    if ($source.Name -eq "Diario de Navarra") { continue }  # ya procesado
    $extra = @(Get-GenericRssItems $source.Name $source.Url)
    foreach ($item in $extra) { $allExtraItems.Add($item) }
}
Write-Log ("Noticias extra recopiladas: " + $allExtraItems.Count)
    $windowStart = $nowDto.AddHours(-30)

    $dnRecent = @($dnItems | Where-Object {
        $_.Published -ge $windowStart -and
        $_.Published -le $nowDto.AddMinutes(10) -and
        $_.Url -notmatch "/(opinion|participacion|multimedia|tag|pags|contenidos)/"
    })
    Write-Log ("Candidatos DN en ventana: " + $dnRecent.Count)

    $sections = @{
        pamplona = @{ Url = "https://www.diariodenavarra.es/noticias/navarra/pamplona-comarca/portada/"; Prefix = "/navarra/pamplona-comarca/"; Heading = "Pamplona y comarca" }
        espana   = @{ Url = "https://www.diariodenavarra.es/noticias/actualidad/nacional/portada/"; Prefix = "/actualidad/nacional/"; Heading = "Nacional" }
        mundial  = @{ Url = "https://www.diariodenavarra.es/noticias/actualidad/internacional/portada/"; Prefix = "/actualidad/internacional/"; Heading = "Internacional" }
    }

    $orders = @{}
    foreach ($key in $sections.Keys) {
        $orders[$key] = @(Get-SectionOrder $sections[$key].Url $sections[$key].Prefix $sections[$key].Heading $nowDto)
    }

    $allDnAndExtra = @($dnRecent) + $allExtraItems.ToArray()
    $allDnAndExtra = @($allDnAndExtra | Where-Object { $null -ne $_ -and $null -ne $_.Url })

    # --- Pamplona: DN con ruta local + fuentes extra con menciones a Pamplona/Navarra ---
    $pamplonaCandidates = @($allDnAndExtra | Where-Object {
        $_.Url -match "/navarra/pamplona-comarca/" -or
        $_.Category -eq "Pamplona y Comarca" -or
        ($_.Source -ne "Diario de Navarra" -and $_.Source -ne "RTVE" -and ($_.Title + " " + $_.Summary) -match "Pamplona|Navarra|Osasuna|Mutilva|Barañáin|Barañain|Burlada|Villava|Ansoáin|Ansoain|Noáin|Noain|Tudela|Estella|Tafalla")
    })

    # --- España: DN con ruta nacional + RTVE + fuentes extra que no sean de Pamplona ---
    $espanaCandidates = @($allDnAndExtra | Where-Object {
        $_.Url -match "/actualidad/nacional/" -or
        $_.Category -eq "Nacional" -or
        $_.Source -eq "RTVE" -or
        ($_.Source -ne "Diario de Navarra" -and ($_.Title + " " + $_.Summary) -notmatch "Pamplona|Navarra")
    })

    # --- Mundial: DN con ruta internacional + RTVE (se completa luego si falta) ---
    $mundialCandidates = @($allDnAndExtra | Where-Object {
        $_.Url -match "/actualidad/internacional/" -or
        $_.Category -eq "Internacional" -or
        $_.Source -eq "RTVE"
    })

    # Osasuna solo entra como refuerzo local si faltan noticias de Pamplona.
    if ($pamplonaCandidates.Count -lt $PerCategory) {
        $osasuna = @($dnRecent | Where-Object { $_.Url -match "/deportes/futbol/osasuna/" })
        $pamplonaCandidates = @($pamplonaCandidates + $osasuna)
    }

    $pamplona = @(Select-ForCategory $pamplonaCandidates @($orders["pamplona"]) $PerCategory)
    $espana   = @(Select-ForCategory $espanaCandidates   @($orders["espana"])   $PerCategory)
    $mundial  = @(Select-ForCategory $mundialCandidates  @($orders["mundial"])  $PerCategory)

    if ($mundial.Count -lt $PerCategory) {
        Write-Log "Completando Mundial con RTVE..."
        $rtve = @(Get-RtveWorld $nowDto 36)
        foreach ($candidate in $rtve) {
            if ($mundial.Count -ge $PerCategory) { break }
            if (Test-DuplicateTitle $candidate.Title $mundial) { continue }
            $mundial += $candidate
        }
    }

    if ($mundial.Count -lt $PerCategory) {
        $rtveOld = @(Get-RtveWorld $nowDto 96)
        foreach ($candidate in $rtveOld) {
            if ($mundial.Count -ge $PerCategory) { break }
            if (Test-DuplicateTitle $candidate.Title $mundial) { continue }
            $mundial += $candidate
        }
    }

    $pamplona = @($pamplona | Select-Object -First $PerCategory)
    $espana = @($espana | Select-Object -First $PerCategory)
    $mundial = @($mundial | Select-Object -First $PerCategory)

    Write-Log ("Seleccionadas: Pamplona=" + $pamplona.Count + ", España=" + $espana.Count + ", Mundial=" + $mundial.Count)
    foreach ($item in $pamplona) { Write-Log ("  P: " + $item.Title) }
    foreach ($item in $espana) { Write-Log ("  E: " + $item.Title) }
    foreach ($item in $mundial) { Write-Log ("  M: " + $item.Title) }

    if (($pamplona.Count + $espana.Count + $mundial.Count) -eq 0) {
        throw "No se ha seleccionado ninguna noticia; no se modifica la página."
    }

    $html = Set-MarkerBlock $html "PAMPLONA" (New-NewsBlock $pamplona $nowDto)
    $html = Set-MarkerBlock $html "ESPANA"   (New-NewsBlock $espana   $nowDto)
    $html = Set-MarkerBlock $html "MUNDIAL"  (New-NewsBlock $mundial  $nowDto)

    $counts = @{ pamplona = $pamplona.Count; espana = $espana.Count; mundial = $mundial.Count }
    $total = $pamplona.Count + $espana.Count + $mundial.Count

    $html = Set-SimpleInner $html '(<p class="kicker" id="edition-kicker">).*?(</p>)' ($dayCap + ", " + $dateLong + " - Pamplona")
    $html = Set-SimpleInner $html '(<strong id="total-count">).*?(</strong>)' ([string]$total)
    $html = Set-SimpleInner $html '(<strong id="edition-time">).*?(</strong>)' $timeLabel
    $html = Set-SimpleInner $html '(<span class="hero-date" aria-hidden="true">).*?(</span>)' $dateMark
    $html = Set-SimpleInner $html '(<p class="footer-note" id="edition-close">).*?(</p>)' ("Edicion cerrada el " + $dateLong + " a las " + $timeLabel + " h. Las noticias evolucionan a lo largo del dia.")
    $html = Set-SimpleInner $html '(<title>).*?(</title>)' ("Hoy en Pamplona - " + $dateLong)

    foreach ($key in @("pamplona", "espana", "mundial")) {
        $html = Set-SimpleInner $html ('(<span class="tab-count" data-count="' + $key + '">).*?(</span>)') (('{0:D2}' -f $counts[$key]))
        $txt = $counts[$key].ToString() + " noticias"
        if ($counts[$key] -eq 1) { $txt = "1 noticia" }
        $html = Set-SimpleInner $html ('(<p class="panel-count" data-count="' + $key + '">).*?(</p>)') $txt
    }

        if ($DryRun) {
        $preview = Join-Path $Root ("preview-" + $Now.ToString("yyyyMMdd-HHmm") + ".html")
        [IO.File]::WriteAllText($preview, $html, $utf8NoBom)
        Write-Log ("DryRun: escrito " + $preview)
        exit 0
    }

    $tempPath = Join-Path $Root "index.html.tmp"
    [IO.File]::WriteAllText($tempPath, $html, $utf8NoBom)
    Move-Item -LiteralPath $tempPath -Destination $indexPath -Force
    Write-Log "Página actualizada correctamente."

    # Abrir la página generada en el navegador predeterminado
    if (-not $NoOpen) { Start-Process $indexPath }

    exit 0
} catch {
    Write-Log ("ERROR: " + $_.Exception.Message)
    Write-Log ("Línea: " + $_.InvocationInfo.ScriptLineNumber)
    exit 1
}
