function New-MarkstrataIndex {
    <#
    .SYNOPSIS
        Generate the landing screens as Markdown: one home index plus one index per category folder.

    .DESCRIPTION
        The index screens are Markdown documents like everything else, so they render through the
        same web part and can be hand-edited afterwards if a category needs a real introduction.

          <libraryRoot>\Home.md                 -> SitePages/<pageRootFolder>/Home.aspx
          <libraryRoot>\<Category>\Index.md     -> SitePages/<pageRootFolder>/<Category>/Index.aspx

        The home index lists the categories, grouped by theme to match the menu; a category index
        lists that category's documents and links back home. Links point at the destination PAGE of
        each document, not at the .md file, so a reader never lands on raw Markdown.

        Deliberately plain: links and headings, no document counts or other derived figures. A count
        written onto a generated page is wrong the moment anyone adds or retires a document without
        re-running, and a stale number is worse than no number.

        Index files are regenerated in place on every run - they are derived artifacts, not
        authored content. Anything you want to keep should live in a normal document.

        Offline: it reads the local synced library and computes destination URLs from config. No
        SharePoint connection. Run Publish-MarkstrataLibrary afterwards to turn the new files into
        pages, and Update-MarkstrataNavigation to point the menu at them.

    .PARAMETER LibraryRoot
        Local root of the synced document library. Defaults to markdown.libraryRoot.

    .PARAMETER PassThru
        Emit one object per index file written instead of only the summary.

    .OUTPUTS
        Summary PSCustomObject (Categories, Documents, Written, LibraryRoot), or per-file objects
        with -PassThru.

    .EXAMPLE
        New-MarkstrataIndex

        Rebuild the home index and every category index from what is currently in the library.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [string]$LibraryRoot,

        [switch]$PassThru
    )

    $config = Get-MarkstrataConfig
    if ([string]::IsNullOrWhiteSpace($LibraryRoot)) { $LibraryRoot = [string]$config.Markdown.libraryRoot }
    if (-not (Test-Path -LiteralPath $LibraryRoot)) {
        throw "Markdown library root not found: $LibraryRoot"
    }

    $indexSettings  = $config.MarkdownIndex
    $homeFileName   = [string]$indexSettings.homeFileName
    $homeTitle      = [string]$indexSettings.homeTitle
    $homeIntro      = [string]$indexSettings.homeIntro
    $backLinkText   = [string]$indexSettings.backLinkText

    $homeLeaf = [System.IO.Path]::GetFileNameWithoutExtension($homeFileName)

    # Gather the documents per category folder, excluding the generated index files themselves -
    # a category must never list itself as one of its own documents.
    # Recurse: the TOP-LEVEL folder is the category, and anything deeper (Alpha\Section\Subsection) is a
    # section within it. Listing only the category folder's own files silently drops every nested
    # document from its index.
    $categories = [ordered]@{}
    foreach ($folder in (Get-ChildItem -LiteralPath $LibraryRoot -Directory)) {
        # The index is now named after its folder, so it can only be excluded by its full path: a
        # name match would also drop a legitimate nested document that happens to share the name
        # (Alpha/Section/Alpha.md), and the category would silently stop listing it.
        $indexFullPath = Join-Path $folder.FullName (Get-MarkdownIndexFileName -Folder $folder.Name)
        $documents = @(Get-ChildItem -LiteralPath $folder.FullName -File -Filter "*.md" -Recurse |
            Where-Object { $_.FullName -ne $indexFullPath -and -not $_.Name.StartsWith("~$") } |
            Sort-Object FullName)
        if ($documents.Count -eq 0) { continue }
        $categories[$folder.Name] = [pscustomobject]@{ Root = $folder.FullName; Documents = $documents }
    }

    if ($categories.Count -eq 0) {
        Write-MarkstrataLog -Message "No category folders with documents under $LibraryRoot." -Level Warning -Component "Index"
        return
    }

    # @(): PowerShell unwraps a single-element array on return, so a library with ONE category
    # would hand back a bare string and every .Count on it would throw under StrictMode.
    $orderedSlugs = @(Get-MarkdownCategoryOrder -FolderSlug @($categories.Keys))
    $results = [System.Collections.Generic.List[object]]::new()
    $documentTotal = 0

    # --- One index per category ----------------------------------------------------------------
    foreach ($slug in $orderedSlugs) {
        $categoryRoot = $categories[$slug].Root
        $documents = $categories[$slug].Documents
        $documentTotal += $documents.Count
        $displayName = Get-MarkdownCategoryDisplayName -FolderSlug $slug

        # Group by the sub-path under the category so nested folders become sections. The category's
        # own documents ("" key) come first, then each sub-path alphabetically.
        $bySubPath = [ordered]@{}
        foreach ($document in $documents) {
            $subPath = $document.Directory.FullName.Substring($categoryRoot.Length).Trim("\", "/") -replace "\\", "/"
            if (-not $bySubPath.Contains($subPath)) { $bySubPath[$subPath] = [System.Collections.Generic.List[object]]::new() }
            $bySubPath[$subPath].Add($document)
        }
        $subPaths = @("") + @($bySubPath.Keys | Where-Object { $_ } | Sort-Object)

        $lines = [System.Collections.Generic.List[string]]::new()
        $lines.Add("# $displayName")
        $lines.Add("")
        foreach ($subPath in $subPaths) {
            if (-not $bySubPath.Contains($subPath)) { continue }
            if ($subPath) {
                $lines.Add("## $($subPath -replace '/', ' / ')")
                $lines.Add("")
            }
            foreach ($document in $bySubPath[$subPath]) {
                $leaf = [System.IO.Path]::GetFileNameWithoutExtension($document.Name)
                $documentFolder = if ($subPath) { "$slug/$subPath" } else { $slug }
                $lines.Add("- $(Format-MarkdownDocumentLink -Folder $documentFolder -LeafName $leaf -Text $leaf -SourceFolder $slug)")
            }
            $lines.Add("")
        }
        # Each section block ends with a blank line; drop it so the divider is not preceded by two.
        while ($lines.Count -gt 0 -and [string]::IsNullOrWhiteSpace($lines[$lines.Count - 1])) {
            $lines.RemoveAt($lines.Count - 1)
        }
        if (-not [string]::IsNullOrWhiteSpace($backLinkText)) {
            $lines.Add("")
            $lines.Add("---")
            $lines.Add("")
            $lines.Add((Format-MarkdownDocumentLink -Folder "" -LeafName $homeLeaf -Text $backLinkText -SourceFolder $slug))
        }

        $indexFileName = Get-MarkdownIndexFileName -Folder $slug
        $indexLeaf = [System.IO.Path]::GetFileNameWithoutExtension($indexFileName)
        $indexPath = Join-Path (Join-Path $LibraryRoot $slug) $indexFileName
        $content = ($lines -join "`n").TrimEnd() + "`n"

        if ($PSCmdlet.ShouldProcess($indexPath, "Write category index")) {
            Set-Content -LiteralPath $indexPath -Value $content -Encoding utf8NoBOM -NoNewline
        }
        $results.Add([pscustomobject]@{
            Scope     = "Category"
            Category  = $displayName
            Folder    = $slug
            Path      = $indexPath
            PageUrl   = (Get-MarkdownPageServerRelativeUrl -Folder $slug -LeafName $indexLeaf)
            Documents = $documents.Count
        })
    }

    # --- The home index -------------------------------------------------------------------------
    $homeLines = [System.Collections.Generic.List[string]]::new()
    $homeLines.Add("# $homeTitle")
    $homeLines.Add("")
    if (-not [string]::IsNullOrWhiteSpace($homeIntro)) {
        $homeLines.Add($homeIntro)
        $homeLines.Add("")
    }
    # Grouped by theme, matching the menu. The menu's group nodes deep-link to these headings, so
    # the heading text and the group name must stay identical - the anchor is generated from it.
    $useGroups = [bool](Get-OptionalProperty $config.Navigation "useGroups" $true)
    $slugByDisplay = @{}
    foreach ($slug in $orderedSlugs) { $slugByDisplay[(Get-MarkdownCategoryDisplayName -FolderSlug $slug)] = $slug }

    # A plain list, not a table: document counts on a generated page go stale the moment anyone
    # adds or retires a document without re-running, and a one-column table is just a list anyway.
    $writeCategoryList = {
        param($Slugs)
        foreach ($categorySlug in $Slugs) {
            $displayName = Get-MarkdownCategoryDisplayName -FolderSlug $categorySlug
            $categoryLeaf = [System.IO.Path]::GetFileNameWithoutExtension((Get-MarkdownIndexFileName -Folder $categorySlug))
            $homeLines.Add("- $(Format-MarkdownDocumentLink -Folder $categorySlug -LeafName $categoryLeaf -Text $displayName)")
        }
    }

    if ($useGroups) {
        foreach ($group in (Get-MarkstrataCategoryGroup -Category @($slugByDisplay.Keys))) {
            $groupSlugs = @($group.Categories | ForEach-Object { $slugByDisplay[$_] } | Where-Object { $_ })
            if ($groupSlugs.Count -eq 0) { continue }
            $homeLines.Add("## $($group.Name)")
            $homeLines.Add("")
            & $writeCategoryList $groupSlugs
            $homeLines.Add("")
        }
    } else {
        & $writeCategoryList $orderedSlugs
    }

    $homePath = Join-Path $LibraryRoot $homeFileName
    $homeContent = ($homeLines -join "`n").TrimEnd() + "`n"
    if ($PSCmdlet.ShouldProcess($homePath, "Write home index")) {
        Set-Content -LiteralPath $homePath -Value $homeContent -Encoding utf8NoBOM -NoNewline
    }
    $results.Add([pscustomobject]@{
        Scope     = "Home"
        Category  = $homeTitle
        Folder    = ""
        Path      = $homePath
        PageUrl   = (Get-MarkdownPageServerRelativeUrl -Folder "" -LeafName $homeLeaf)
        Documents = $documentTotal
    })

    Write-MarkstrataLog -Message "Index written: $($orderedSlugs.Count) category index file(s) + home, covering $documentTotal document(s)." -Component "Index"

    if ($PassThru) { return $results }

    return [pscustomobject]@{
        LibraryRoot = $LibraryRoot
        Categories  = $orderedSlugs.Count
        Documents   = $documentTotal
        Written     = $results.Count
        HomePath    = $homePath
    }
}
