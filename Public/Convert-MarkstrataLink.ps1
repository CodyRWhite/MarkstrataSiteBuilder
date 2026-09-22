function Convert-MarkstrataLink {
    <#
    .SYNOPSIS
        Convert internal links between page links and wiki links across the whole library.

    .DESCRIPTION
        Two ways of pointing one document at another:

          page link  [read page one](/sites/docs/SitePages/Docs/Alpha/Section/Page One.aspx)
          wiki link  [[Alpha/Section/Page One|read page one]]

        A wiki link addresses the DOCUMENT by its path in the library; a page link addresses the
        rendered page by URL. The wiki form is shorter, survives the page root folder being renamed
        (nothing in it names SitePages or the Docs prefix), and is validated by the web part when
        checkWikiLinks is on.

        Both directions are supported, so the choice is reversible: -UseWikiLinks converts page
        links to wiki links, -UsePageLinks converts them back.

        Only links whose target document actually exists in the library are converted. A link that
        cannot be resolved is left exactly as it was and reported, because silently turning a
        working page link into a broken wiki link would be worse than leaving it alone.

        Image references are never touched.

    .PARAMETER UseWikiLinks
        Convert page links to wiki links.

    .PARAMETER UsePageLinks
        Convert wiki links back to page links.

    .PARAMETER LibraryRoot
        Local root of the synced document library. Defaults to markdown.libraryRoot.

    .PARAMETER PassThru
        Emit one object per document changed instead of only the summary.

    .OUTPUTS
        PSCustomObject summary (Direction, DocumentsScanned, DocumentsChanged, LinksConverted,
        Unresolved).

    .EXAMPLE
        Convert-MarkstrataLink -UseWikiLinks -WhatIf

        Report how many links would convert, and which targets cannot be resolved.

    .EXAMPLE
        Convert-MarkstrataLink -UsePageLinks

        Put everything back to absolute page URLs.
    #>
    [CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = "Wiki")]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, ParameterSetName = "Wiki")]
        [switch]$UseWikiLinks,

        [Parameter(Mandatory, ParameterSetName = "Page")]
        [switch]$UsePageLinks,

        [string]$LibraryRoot,

        [switch]$PassThru
    )

    $config = Get-MarkstrataConfig
    if ([string]::IsNullOrWhiteSpace($LibraryRoot)) { $LibraryRoot = [string]$config.Markdown.libraryRoot }
    if (-not (Test-Path -LiteralPath $LibraryRoot)) { throw "Markdown library root not found: $LibraryRoot" }

    # Every document in the library, keyed by its library-relative path without the extension -
    # which is exactly what a wiki link names.
    $documentPaths = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($file in (Get-ChildItem -LiteralPath $LibraryRoot -Recurse -File -Filter "*.md")) {
        $relative = $file.FullName.Substring($LibraryRoot.Length).TrimStart("\", "/") -replace "\\", "/"
        [void]$documentPaths.Add(($relative -replace '\.md$', ''))
    }

    $pageRoot = Get-MarkdownPageFolderPath -Folder ""
    $pagesSegment = ([string]$config.SharePoint.pagesLibrary).Replace(" ", "")
    $siteRoot = Get-MarkstrataSiteRelativeRoot
    $pagePrefix = "$siteRoot/$pagesSegment"
    if ($pageRoot) { $pagePrefix += "/$pageRoot" }

    $direction = if ($UseWikiLinks) { "PageToWiki" } elseif ($UsePageLinks) { "WikiToPage" } else { "WikiToPage" }
    Write-MarkstrataLog -Message "Converting links ($direction) across $($documentPaths.Count) document(s)." -Component "Link"

    # Fenced and inline code are excluded from both directions: a page documenting the link syntax
    # writes [[Folder/Document]] as an EXAMPLE, and converting it rewrites the documentation the
    # moment the example target happens to resolve.
    #
    # (?<!!) so an image reference is never matched.
    # The fragment is captured separately: a heading anchor is carried across unchanged, and
    # without this an anchored link matches neither pattern and is silently left behind.
    $pageLinkPattern = '(?<!!)\[(?<text>[^\]]*)\]\((?<url>' + [regex]::Escape($pagePrefix) + '/[^)#]+\.aspx)(?<fragment>#[^)]*)?\)'
    $wikiLinkPattern = '\[\[(?<target>[^\]|#]+)(?<fragment>#[^\]|]*)?(?:\|(?<text>[^\]]*))?\]\]'

    $results = [System.Collections.Generic.List[object]]::new()
    $unresolved = [System.Collections.Generic.List[string]]::new()
    $scanned = 0; $changed = 0; $converted = 0

    foreach ($file in (Get-ChildItem -LiteralPath $LibraryRoot -Recurse -File -Filter "*.md" | Sort-Object FullName)) {
        $scanned++
        $text = Get-Content -LiteralPath $file.FullName -Raw
        if ([string]::IsNullOrEmpty($text)) { continue }
        $original = $text
        $fileConverted = 0

        # A wiki link resolves against the folder of the document it is written in, so the target
        # is relative to THIS document, not to the library root.
        $sourceFolder = ""
        $sourceRelative = $file.FullName.Substring($LibraryRoot.Length).TrimStart("\", "/") -replace "\\", "/"
        if ($sourceRelative.Contains("/")) {
            $sourceFolder = $sourceRelative.Substring(0, $sourceRelative.LastIndexOf("/"))
        }

        if ($UseWikiLinks) {
            $text = Convert-MarkdownOutsideCode -Text $text -Pattern $pageLinkPattern -Evaluator {
                param($match)
                $url = $match.Groups["url"].Value
                $display = $match.Groups["text"].Value

                $relative = $url.Substring($pagePrefix.Length).TrimStart("/")
                $target = [uri]::UnescapeDataString($relative) -replace '\.aspx$', ''

                if (-not $documentPaths.Contains($target)) {
                    $unresolved.Add("$($file.Name): $target")
                    return $match.Value
                }

                $script:linkTally++
                $leaf = $target.Substring($target.LastIndexOf("/") + 1)
                $targetFolder = if ($target.Contains("/")) { $target.Substring(0, $target.LastIndexOf("/")) } else { "" }
                $relative = Get-RelativeDocumentTarget -FromFolder $sourceFolder -ToFolder $targetFolder -LeafName $leaf
                $fragment = $match.Groups["fragment"].Value
                # Without a pipe the web part renders the WHOLE target as the label, so a link into
                # a subfolder reads "Section/Subsection/Page Three". Only omit it when the target
                # is already a bare name in the same folder.
                if ($display -eq $relative -and -not $fragment) { return "[[$relative]]" }
                return "[[$relative$fragment|$display]]"
            }
        } else {
            $text = Convert-MarkdownOutsideCode -Text $text -Pattern $wikiLinkPattern -Evaluator {
                param($match)
                $rawTarget = $match.Groups["target"].Value.Trim()
                $target = Resolve-LibraryDocumentPath -FromFolder $sourceFolder -Target $rawTarget
                if (-not $documentPaths.Contains($target)) {
                    # Tolerate a target written from the LIBRARY ROOT rather than relative to this
                    # document. The web part resolves relative, so those links are broken - but
                    # reading them is exactly how a library written in the old form gets migrated.
                    $rootCandidate = Resolve-LibraryDocumentPath -FromFolder "" -Target $rawTarget
                    if ($documentPaths.Contains($rootCandidate)) { $target = $rootCandidate }
                }
                $display = if ($match.Groups["text"].Success -and $match.Groups["text"].Value) {
                    $match.Groups["text"].Value
                } else {
                    $rawTarget.Substring($rawTarget.LastIndexOf("/") + 1)
                }

                if (-not $documentPaths.Contains($target)) {
                    $unresolved.Add("$($file.Name): $rawTarget")
                    return $match.Value
                }

                $script:linkTally++
                $folder = ""
                $leaf = $target
                if ($target.Contains("/")) {
                    $folder = $target.Substring(0, $target.LastIndexOf("/"))
                    $leaf = $target.Substring($target.LastIndexOf("/") + 1)
                }
                $url = ConvertTo-MarkdownLinkUrl -Url (Get-MarkdownPageServerRelativeUrl -Folder $folder -LeafName $leaf)
                return "[$display]($url$($match.Groups['fragment'].Value))"
            }
        }

        $fileConverted = $script:linkTally
        $script:linkTally = 0

        if ($text -ne $original) {
            if ($PSCmdlet.ShouldProcess($file.FullName, "Convert links ($direction)")) {
                Set-Content -LiteralPath $file.FullName -Value $text -Encoding utf8NoBOM -NoNewline
            }
            $changed++
            $converted += $fileConverted
            $results.Add([pscustomobject]@{
                Document = $file.FullName.Substring($LibraryRoot.Length).TrimStart("\")
                Links    = $fileConverted
            })
        }
    }

    Write-MarkstrataLog -Message "Links converted: $converted in $changed document(s) of $scanned scanned." -Component "Link"
    if ($unresolved.Count -gt 0) {
        Write-MarkstrataLog -Message "Left unchanged (target not in the library): $($unresolved.Count)." -Level Warning -Component "Link"
    }

    if ($PassThru) { return $results }

    return [pscustomobject]@{
        Direction        = $direction
        DocumentsScanned = $scanned
        DocumentsChanged = $changed
        LinksConverted   = $converted
        Unresolved       = @($unresolved | Sort-Object -Unique)
    }
}
