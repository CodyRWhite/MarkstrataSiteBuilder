<#
    Path helpers for the Markdown pipeline. Both halves - the converter that writes the .md tree
    and the scripter that builds pages from it - derive their names here, so a page can never end
    up pointing at a file name the converter did not actually write.
#>

function ConvertTo-SafeLeafName {
    <#
    .SYNOPSIS
        Make a title safe as a SharePoint file/page leaf name.
    .DESCRIPTION
        SharePoint rejects " * : < > ? / \ | and # %, will not accept a leaf that starts or ends
        with a space or a period, and treats "~$" as a lock-file prefix. Characters are replaced
        rather than dropped so two different titles do not collapse onto the same name.
    .PARAMETER Name
        The title to sanitize.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Name)

    $safe = $Name -replace '[\\/:*?"<>|#%]', "-"
    $safe = $safe -replace '\s+', " "
    $safe = $safe.Trim().Trim(".").Trim()
    if ($safe.StartsWith("~$")) { $safe = $safe.Substring(2).Trim() }
    if ([string]::IsNullOrWhiteSpace($safe)) { $safe = "Untitled" }
    # SharePoint's practical limit is the full path, not the leaf; 120 keeps headroom for the
    # library + category folder without truncating any real title we have.
    if ($safe.Length -gt 120) { $safe = $safe.Substring(0, 120).Trim() }
    return $safe
}

function Get-MarkstrataSiteRelativeRoot {
    <#
    .SYNOPSIS
        The target site's server-relative path (for example "/sites/docs"), from config.
    .DESCRIPTION
        Derived from sharePoint.siteUrl rather than a live connection, so the Markdown half of the
        pipeline runs fully offline.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $config = Get-MarkstrataConfig
    $path = ([uri]$config.SharePoint.siteUrl).AbsolutePath.TrimEnd("/")
    if ([string]::IsNullOrWhiteSpace($path)) { return "" }
    return $path
}

function Get-MarkdownPageServerRelativeUrl {
    <#
    .SYNOPSIS
        Server-relative URL of the modern page generated for a Markdown document.
    .PARAMETER Folder
        Category folder (may be empty for a document at the library root).
    .PARAMETER LeafName
        The document's safe leaf name, without extension.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowEmptyString()][string]$Folder,
        [Parameter(Mandatory)][string]$LeafName
    )

    $config = Get-MarkstrataConfig
    $segments = @((Get-MarkstrataSiteRelativeRoot), $config.SharePoint.pagesLibrary.Replace(" ", ""))
    $rootFolder = [string]$config.MarkdownPage.pageRootFolder
    if (-not [string]::IsNullOrWhiteSpace($rootFolder)) { $segments += $rootFolder }
    if (-not [string]::IsNullOrWhiteSpace($Folder))     { $segments += $Folder }
    $segments += "$LeafName.aspx"
    return (($segments | Where-Object { $_ }) -join "/")
}

function Get-MarkdownPageFolderPath {
    <#
    .SYNOPSIS
        The Site Pages folder (relative to the library) that a document's page is created in.
    .PARAMETER Folder
        Category folder (may be empty).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowEmptyString()][string]$Folder)

    $config = Get-MarkstrataConfig
    $segments = @()
    $rootFolder = [string]$config.MarkdownPage.pageRootFolder
    if (-not [string]::IsNullOrWhiteSpace($rootFolder)) { $segments += $rootFolder }
    if (-not [string]::IsNullOrWhiteSpace($Folder))     { $segments += $Folder }
    return ($segments -join "/")
}

function Get-MarkdownCategoryDisplayName {
    <#
    .SYNOPSIS
        Turn a category FOLDER slug back into its display name ("Gamma and Delta" -> "Gamma & Delta").
    .DESCRIPTION
        Folders are slugs because SharePoint will not take "&" in a path. The reverse map is built
        by slugifying each entry of categories.json and matching; a folder with no matching entry
        (a category added by hand in the library) is its own display name.
    .PARAMETER FolderSlug
        The folder name as it appears in the library.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$FolderSlug)

    if ([string]::IsNullOrWhiteSpace($FolderSlug)) { return "" }
    foreach ($category in (Get-MarkstrataCategoryList).List) {
        if ((ConvertTo-CategorySlug -Category $category) -eq $FolderSlug) { return $category }
    }
    return $FolderSlug
}

function Get-MarkdownCategoryOrder {
    <#
    .SYNOPSIS
        Order category folder slugs: the categories.json sequence first, then anything else A-Z.
    .DESCRIPTION
        categories.json drives the index and menu order. Folders it does not mention are still
        included - the library is allowed to grow beyond the wiki's categories - and are appended
        alphabetically rather than dropped.
    .PARAMETER FolderSlug
        The folder slugs present in the library.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([string[]]$FolderSlug = @())

    $present = [System.Collections.Generic.List[string]]::new()
    foreach ($slug in ($FolderSlug | Where-Object { $_ } | Sort-Object -Unique)) { $present.Add($slug) }

    $ordered = [System.Collections.Generic.List[string]]::new()
    foreach ($category in (Get-MarkstrataCategoryList).List) {
        $slug = ConvertTo-CategorySlug -Category $category
        if ($present.Contains($slug)) {
            $ordered.Add($slug)
            [void]$present.Remove($slug)
        }
    }
    foreach ($slug in ($present | Sort-Object)) { $ordered.Add($slug) }
    return $ordered.ToArray()
}

function ConvertTo-MarkdownLinkUrl {
    <#
    .SYNOPSIS
        Percent-encode a server-relative URL so it survives as a Markdown link destination.
    .PARAMETER Url
        The URL to encode.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Url)

    return $Url.Replace(" ", "%20").Replace("(", "%28").Replace(")", "%29")
}

function Get-RelativeDocumentTarget {
    <#
    .SYNOPSIS
        Express one document's location relative to the folder of the document linking to it.

    .DESCRIPTION
        The Markdown web part resolves a wiki link against the folder of the document it appears
        in, not against the library root. A category index sitting in Alpha that links to
        "Alpha/Section/Page One" therefore resolves to Alpha/Alpha/Section/Page One and fails -
        the folder must not name itself.

        This walks up from the source folder to the nearest common ancestor and back down to the
        target, which gives a link that resolves from wherever it is written.

    .PARAMETER FromFolder
        Library-relative folder of the document containing the link. Empty for the library root.

    .PARAMETER ToFolder
        Library-relative folder of the target document. Empty for the library root.

    .PARAMETER LeafName
        Target document name, without the .md extension.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowEmptyString()][string]$FromFolder,
        [AllowEmptyString()][string]$ToFolder,
        [Parameter(Mandatory)][string]$LeafName
    )

    $fromParts = @(($FromFolder -replace "\\", "/") -split "/" | Where-Object { $_ })
    $toParts   = @(($ToFolder   -replace "\\", "/") -split "/" | Where-Object { $_ })

    $common = 0
    while ($common -lt $fromParts.Count -and $common -lt $toParts.Count -and
           $fromParts[$common] -eq $toParts[$common]) { $common++ }

    $segments = [System.Collections.Generic.List[string]]::new()
    for ($step = $common; $step -lt $fromParts.Count; $step++) { $segments.Add("..") }
    for ($step = $common; $step -lt $toParts.Count; $step++) { $segments.Add($toParts[$step]) }
    $segments.Add($LeafName)

    return ($segments -join "/")
}

function Get-MarkdownIndexFileName {
    <#
    .SYNOPSIS
        File name of a category's index document.

    .DESCRIPTION
        The index is named after its own folder - "Alpha/Alpha.md", "Gamma and Delta/Gamma and
        Delta.md" - so the menu entry, the page title and the file all read the same. A fixed
        "Index.md" made every category's menu entry and browser tab say "Index", and gave the
        library one file per category all sharing that name.

        markdownIndex.indexFileName is a PATTERN, not a literal: "{Category}" is replaced with the
        folder's own name, case preserved exactly as the folder spells it. A pattern with no token
        still works and behaves as the old fixed leaf.

    .PARAMETER Folder
        Library-relative folder of the category. The deepest segment is the name used, so a nested
        folder gets an index named after itself rather than after its category.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Folder
    )

    $config = Get-MarkstrataConfig
    $pattern = [string](Get-OptionalProperty $config.MarkdownIndex "indexFileName" "{Category}.md")

    # @(): a single-segment folder splits to a bare string, and [-1] on a string is its last
    # CHARACTER, so "Alpha" would produce an index called "a.md".
    $segments = @(($Folder -replace "\\", "/") -split "/" | Where-Object { $_ })
    if ($segments.Count -eq 0) { return $pattern.Replace("{Category}", "Index") }

    return $pattern.Replace("{Category}", $segments[-1])
}

function Get-MarkdownRendererUrl {
    <#
    .SYNOPSIS
        URL that renders one document through the single shared renderer page.

    .DESCRIPTION
        The Markdown web part can be told which document to show through a query string, so ONE
        page can serve the whole library:

            /sites/docs/SitePages/Wiki.aspx?strataDoc=%2Fsites%2Fdocs%2FShared%20Documents%2FAlpha%2FPage%20One.md

        That is what removes the need for a page per document. The value is the document's
        LIBRARY-relative path, including the .md extension; how much of it is escaped is
        markdownPage.strataDocEncoding, but "%", "&", "#" and "+" are always escaped.

        The home index is the exception: it is the renderer's own selectedFile, so it comes back
        as the bare page URL with no query string at all.

    .PARAMETER Folder
        Library-relative folder of the document. Empty for the library root.

    .PARAMETER FileName
        Document file name, including the .md extension.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowEmptyString()][string]$Folder,
        [Parameter(Mandatory)][string]$FileName
    )

    $config = Get-MarkstrataConfig
    $renderer = [string](Get-OptionalProperty $config.MarkdownPage "rendererPage" "Wiki.aspx")
    # The PAGE half is absolute (scheme and host), while the strataDoc value stays server-relative.
    # A navigation node built from a server-relative page URL does not carry its query string
    # through reliably, so the form that works is the one SharePoint itself hands you.
    $pagesSegment = ([string]$config.SharePoint.pagesLibrary).Replace(" ", "")
    $siteUri = [uri]$config.SharePoint.siteUrl
    $origin = "{0}://{1}" -f $siteUri.Scheme, $siteUri.Authority
    $rendererUrl = "{0}{1}/{2}/{3}" -f $origin, (Get-MarkstrataSiteRelativeRoot), $pagesSegment, $renderer

    # The value is LIBRARY-relative ("Gamma and Delta/Index.md"), not the full server-relative
    # path. The web part already knows which library it is bound to, so repeating
    # /sites/docs/Shared Documents/ on every link just makes the URL long.
    $documentUrl = if ([string]::IsNullOrWhiteSpace($Folder)) { $FileName } else { "$Folder/$FileName" }

    # The renderer's OWN selectedFile is the home index, so the bare page URL already shows it.
    # Appending ?strataDoc=Home.md would ask for exactly what the page renders by default - it is
    # the base URL, and spelling out the default makes the home link look like a deep link.
    $defaultDocument = [string](Get-OptionalProperty $config.MarkdownIndex "homeFileName" "Home.md")
    if ($documentUrl -eq $defaultDocument) { return $rendererUrl }

    # How much of the path to encode. "full" is what SharePoint itself produces when you copy a
    # path, and is the only form guaranteed to survive any intermediary. "spaces" keeps the slashes
    # readable while still encoding the one character a URL genuinely cannot carry raw. "none" is
    # the prettiest and the most fragile - a raw space in a query string is not valid.
    $encoding = [string](Get-OptionalProperty $config.MarkdownPage "strataDocEncoding" "full")

    # Three characters are never optional, whatever the mode, and two of them fail SILENTLY:
    #   &  splits the query string, so the document simply never opens and nothing is reported
    #   #  is taken by the browser as the page fragment and never reaches the web part at all
    #   +  decodes to a space, so the web part looks for a file name that does not exist
    # "%" goes first, or the escapes introduced below would themselves be re-read as escapes.
    $minimal = $documentUrl.Replace("%", "%25").Replace("&", "%26").Replace("#", "%23").Replace("+", "%2B")

    $encoded = switch ($encoding) {
        "none"   { $minimal }
        "spaces" { $minimal.Replace(" ", "%20") }
        default  { [uri]::EscapeDataString($documentUrl) }
    }

    return "{0}?strataDoc={1}" -f $rendererUrl, $encoded
}

function Resolve-LibraryDocumentPath {
    <#
    .SYNOPSIS
        Turn a wiki-link target, written relative to a document, back into a library path.

    .DESCRIPTION
        The inverse of Get-RelativeDocumentTarget. A target such as "../Alpha/Index" written inside
        Beta/Index.md resolves to "Alpha/Index"; a bare "Page Two" written in the same document
        resolves to "Beta/Page Two".

        A target that climbs above the library root is clamped there rather than producing a path
        with leading "..", which would never match a document.

    .PARAMETER FromFolder
        Library-relative folder of the document containing the link. Empty for the library root.

    .PARAMETER Target
        The wiki-link target as written.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowEmptyString()][string]$FromFolder,
        [Parameter(Mandatory)][string]$Target
    )

    $segments = [System.Collections.Generic.List[string]]::new()
    foreach ($part in (($FromFolder -replace "\\", "/") -split "/" | Where-Object { $_ })) { $segments.Add($part) }

    foreach ($part in (($Target.TrimStart("/") -replace "\\", "/") -split "/")) {
        if ($part -eq "." -or $part -eq "") { continue }
        if ($part -eq "..") {
            if ($segments.Count -gt 0) { $segments.RemoveAt($segments.Count - 1) }
            continue
        }
        $segments.Add($part)
    }

    return ($segments -join "/")
}

function Format-MarkdownDocumentLink {
    <#
    .SYNOPSIS
        Render a link to another document, as either a wiki link or a page link.

    .DESCRIPTION
        Every generated link goes through here so the whole library uses one form. Without it the
        index screens would keep emitting page links and quietly revert the library to mixed style
        on the next run, whatever Convert-MarkstrataLink had just done.

        markdown.useWikiLinks picks the form:

          wiki   [[<Folder>/<Leaf>|<Text>]]   - addresses the DOCUMENT in the library
          page   [<Text>](<server-relative page URL>)

        The pipe is dropped when the display text is just the document name, since the web part
        falls back to it.

    .PARAMETER Folder
        Category folder of the target, relative to the library root. Empty for the library root.

    .PARAMETER LeafName
        Target document name, without the .md extension.

    .PARAMETER Text
        Display text.

    .PARAMETER SourceFolder
        Library-relative folder of the document the link is written INTO. A wiki link resolves
        against this folder, not the library root, so it decides the target path.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowEmptyString()][string]$Folder,
        [Parameter(Mandatory)][string]$LeafName,
        [Parameter(Mandatory)][string]$Text,
        [AllowEmptyString()][string]$SourceFolder = ""
    )

    $config = Get-MarkstrataConfig
    if ([bool](Get-OptionalProperty $config.Markdown "useWikiLinks" $false)) {
        $target = Get-RelativeDocumentTarget -FromFolder $SourceFolder -ToFolder $Folder -LeafName $LeafName
        # Without a pipe the web part renders the WHOLE target as the label, so a link into a
        # subfolder reads "Section/Subsection/Page Three".
        # The pipe is only safe to omit when the target is a bare name in the same folder.
        if ($Text -eq $target) { return "[[$target]]" }
        return "[[$target|$Text]]"
    }

    $url = ConvertTo-MarkdownLinkUrl -Url (Get-MarkdownPageServerRelativeUrl -Folder $Folder -LeafName $LeafName)
    return "[$Text]($url)"
}

function Get-MarkdownFileServerRelativeUrl {
    <#
    .SYNOPSIS
        Server-relative URL of a .md file inside the synced document library.
    .PARAMETER Folder
        Category folder (may be empty).
    .PARAMETER FileName
        The file name including its .md extension.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowEmptyString()][string]$Folder,
        [Parameter(Mandatory)][string]$FileName
    )

    $config = Get-MarkstrataConfig
    $segments = @([string]$config.Markdown.libraryServerRelativeUrl.TrimEnd("/"))
    if (-not [string]::IsNullOrWhiteSpace($Folder)) { $segments += $Folder }
    $segments += $FileName
    return ($segments -join "/")
}

function Convert-MarkdownOutsideCode {
    <#
    .SYNOPSIS
        Apply a regex replacement to a Markdown document, leaving code untouched.

    .DESCRIPTION
        A page that documents the link syntax writes [[Folder/Document]] or a page URL as an
        EXAMPLE. A plain replace rewrites those examples the moment the example target happens to
        resolve, so the documentation for the syntax silently stops showing the syntax.

        Fenced blocks (``` or ~~~) and inline spans (`...`) are copied through verbatim and the
        replacement runs only on what is between them. The closing fence must be the same character
        repeated at least as many times as the opening one, and an unclosed fence runs to the end of
        the document, both as CommonMark has it.

        The evaluator keeps seeing the variables of the function that defined it, which is what lets
        callers keep using their own counters and lookup tables.

    .PARAMETER Text
        The whole document.

    .PARAMETER Pattern
        Regex to replace outside code.

    .PARAMETER Evaluator
        MatchEvaluator scriptblock, as [regex]::Replace takes.

    .OUTPUTS
        String - the document with the replacement applied outside code only.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)][string]$Pattern,
        [Parameter(Mandatory)][scriptblock]$Evaluator
    )

    if ([string]::IsNullOrEmpty($Text)) { return $Text }

    # Fenced first: a fence can contain backticks, and matching inline spans first would cut one in
    # half. \k<fence> holds the closing run to the opening one; \z ends an unclosed block.
    $codePattern = '(?m)^[ ]{0,3}(?<fence>`{3,}|~{3,})[^\r\n]*\r?\n[\s\S]*?(?:^[ ]{0,3}\k<fence>[ \t]*\r?$|\z)' +
                   '|(?<tick>`+)[\s\S]*?\k<tick>'

    $builder = [System.Text.StringBuilder]::new()
    $position = 0
    foreach ($code in [regex]::Matches($Text, $codePattern)) {
        if ($code.Index -gt $position) {
            [void]$builder.Append([regex]::Replace($Text.Substring($position, $code.Index - $position), $Pattern, $Evaluator))
        }
        [void]$builder.Append($code.Value)
        $position = $code.Index + $code.Length
    }
    if ($position -lt $Text.Length) {
        [void]$builder.Append([regex]::Replace($Text.Substring($position), $Pattern, $Evaluator))
    }

    return $builder.ToString()
}
