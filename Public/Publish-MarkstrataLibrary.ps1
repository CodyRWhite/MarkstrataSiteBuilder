function Publish-MarkstrataLibrary {
    <#
    .SYNOPSIS
        Walk the Markdown document library and publish one modern page per .md file.

    .DESCRIPTION
        Pass 2 of the Markdown pipeline, and the command that replaces the old HTML page builder.
        It enumerates markdown.libraryServerRelativeUrl recursively, and for every .md file creates
        a SingleWebPartAppPage at SitePages/<markdownPage.pageRootFolder>/<folder>/<name>.aspx whose
        single Markdown web part points back at that file.

        The library - not the local synced folder - is the source of truth: a page can only render
        a file SharePoint actually holds, so enumerating the library guarantees every page created
        has something to show. Let OneDrive finish syncing before running this.

        Because the pages reference the Markdown rather than embedding it, re-running after editing
        a document changes nothing on the page and is unnecessary: run it when documents are ADDED,
        MOVED or RENAMED.

    .PARAMETER Folder
        Restrict the walk to one folder inside the library (for example "Alpha"). Omit for everything.

    .PARAMETER Limit
        Stop after this many documents. Useful for a first run against a handful of pages.

    .PARAMETER Force
        Recreate pages that already exist, instead of leaving them alone.

    .PARAMETER OrphanOnly
        Skip publishing entirely and only sweep orphaned pages. Use it after a publish run has
        already happened - re-publishing every page just to reach the sweep costs a full run for
        no change. Implies -RemoveOrphan.

    .PARAMETER RemoveOrphan
        Recycle pages under the page root whose Markdown document no longer exists. Deleting a .md
        does NOT remove its page - the page simply renders nothing - so after retiring documents
        this is what clears the leftovers. Index and home pages are never treated as orphans.

        Also recycles any FOLDER left empty afterwards. Removing the pages does not remove the
        folder that held them, so a retired category otherwise lingers in Site Contents as an empty
        folder. Folders are swept deepest first, because emptying a child can leave its parent
        empty in the same pass.

    .PARAMETER PassThru
        Emit one result object per page instead of only the summary.

    .OUTPUTS
        PSCustomObject summary (Documents, Created, Updated, Skipped, Failed, Elapsed), or
        per-page objects with -PassThru.

    .EXAMPLE
        Connect-MarkstrataSite
        Publish-MarkstrataLibrary -Folder "Alpha"

        Build pages for the Alpha documents only.

    .EXAMPLE
        Publish-MarkstrataLibrary -WhatIf

        List the pages that would be created, touching nothing.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [string]$Folder = "",

        [int]$Limit = 0,

        [switch]$Force,

        [switch]$RemoveOrphan,

        [switch]$OrphanOnly,

        [switch]$PassThru
    )

    if (-not $script:SharePointReady) {
        throw "Not connected. Run Connect-MarkstrataSite first."
    }

    $config = Get-MarkstrataConfig
    $libraryUrl = [string]$config.Markdown.libraryServerRelativeUrl.TrimEnd("/")
    if ([string]::IsNullOrWhiteSpace($libraryUrl)) {
        throw "markdown.libraryServerRelativeUrl is not configured."
    }

    # Get-PnPFolderItem takes a SITE-relative path ("Shared Documents/Alpha"), while the config holds
    # the server-relative one ("/sites/docs/Shared Documents") that the web part needs. Passing
    # the server-relative form returns nothing at all rather than failing, so convert it here.
    $siteRoot = Get-MarkstrataSiteRelativeRoot
    $librarySiteRelative = $libraryUrl
    if ($siteRoot -and $librarySiteRelative.StartsWith($siteRoot, [StringComparison]::OrdinalIgnoreCase)) {
        $librarySiteRelative = $librarySiteRelative.Substring($siteRoot.Length)
    }
    $librarySiteRelative = $librarySiteRelative.Trim("/")

    $startUrl = if ([string]::IsNullOrWhiteSpace($Folder)) { $librarySiteRelative } else { "$librarySiteRelative/$Folder" }
    Write-MarkstrataLog -Message "Scanning Markdown library: $startUrl" -Component "MarkdownPage"

    # Recursive walk. Get-PnPFolderItem is not recursive, so folders are queued and drained;
    # "Forms" is the library's own template folder and never holds content.
    $documents = [System.Collections.Generic.List[object]]::new()
    $pending = [System.Collections.Generic.Queue[string]]::new()
    $pending.Enqueue($startUrl)

    while ($pending.Count -gt 0) {
        $currentUrl = $pending.Dequeue()
        $relativeFolder = $currentUrl.Substring([Math]::Min($currentUrl.Length, $librarySiteRelative.Length)).Trim("/")

        try {
            $files = @(Get-PnPFolderItem -FolderSiteRelativeUrl $currentUrl -ItemType File -ErrorAction Stop)
            $folders = @(Get-PnPFolderItem -FolderSiteRelativeUrl $currentUrl -ItemType Folder -ErrorAction Stop)
        } catch {
            Write-MarkstrataLog -Message "Cannot read folder '$currentUrl': $($_.Exception.Message)" -Level Warning -Component "MarkdownPage"
            continue
        }

        foreach ($file in $files) {
            if ($file.Name -notlike "*.md") { continue }
            if ($file.Name.StartsWith("~$") -or $file.Name.StartsWith(".")) { continue }
            $documents.Add([pscustomobject]@{
                Name   = [string]$file.Name
                Folder = $relativeFolder
                Length = [long]$file.Length
            })
        }
        foreach ($subFolder in $folders) {
            if ($subFolder.Name -in @("Forms")) { continue }
            if ($subFolder.Name.StartsWith(".")) { continue }
            $pending.Enqueue("$currentUrl/$($subFolder.Name)")
        }
    }

    if ($documents.Count -eq 0) {
        Write-MarkstrataLog -Message "No Markdown documents found under $startUrl." -Level Warning -Component "MarkdownPage"
        return [pscustomobject]@{ Documents = 0; Created = 0; Updated = 0; Skipped = 0; Failed = 0; Elapsed = [TimeSpan]::Zero }
    }

    $ordered = @($documents | Sort-Object Folder, Name)
    if ($Limit -gt 0 -and $ordered.Count -gt $Limit) { $ordered = @($ordered | Select-Object -First $Limit) }
    $total = $ordered.Count

    Write-MarkstrataLog -Message "Building $total page(s) from Markdown documents." -Component "MarkdownPage"

    $results = [System.Collections.Generic.List[object]]::new()
    $created = 0; $updated = 0; $skipped = 0; $failed = 0
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $index = 0

    $homeFileName  = [string]$config.MarkdownIndex.homeFileName

    if ($OrphanOnly) {
        $RemoveOrphan = $true
        Write-MarkstrataLog -Message "Sweep only: skipping the publish pass." -Component "MarkdownPage"
    }

    foreach ($document in $(if ($OrphanOnly) { @() } else { $ordered })) {
        $index++
        $leafName = [System.IO.Path]::GetFileNameWithoutExtension($document.Name)

        # An index screen is named after its own folder, so its page title is the category's
        # DISPLAY name rather than the folder slug - "Gamma & Delta", not "Gamma and Delta".
        # Everything else is titled by its file name.
        $pageTitle = $leafName
        if ($document.Folder -and $document.Name -eq (Get-MarkdownIndexFileName -Folder $document.Folder)) {
            $pageTitle = Get-MarkdownCategoryDisplayName -FolderSlug ($document.Folder -split "/")[-1]
        } elseif (-not $document.Folder -and $document.Name -eq $homeFileName) {
            $pageTitle = [string]$config.MarkdownIndex.homeTitle
        }

        $pageArguments = @{
            FileName = $document.Name
            Folder   = $document.Folder
            Title    = $pageTitle
            Length   = $document.Length
        }
        if ($Force) { $pageArguments["Force"] = $true }
        # Category is the TOP-LEVEL folder - the library's structure IS the taxonomy now. A nested
        # folder (Alpha/Section/Subsection) is a section inside Alpha, not a category of its own,
        # so the last segment would file those documents under "Subsection".
        if ($document.Folder) { $pageArguments["Category"] = ($document.Folder -split "/")[0] }

        if ($PSCmdlet.ShouldProcess((Get-MarkdownPageServerRelativeUrl -Folder $document.Folder -LeafName $leafName), "Create Markdown page")) {
            $pageResult = New-MarkstrataPage @pageArguments
        } else {
            $pageResult = [pscustomobject]@{
                Title = $leafName; PageName = "$leafName.aspx"
                Url = (Get-MarkdownPageServerRelativeUrl -Folder $document.Folder -LeafName $leafName)
                MarkdownUrl = (Get-MarkdownFileServerRelativeUrl -Folder $document.Folder -FileName $document.Name)
                Status = "WhatIf"; Message = ""
            }
        }

        switch ($pageResult.Status) {
            "Created" { $created++ }
            "Updated" { $updated++ }
            "Skipped" { $skipped++ }
            "Failed"  { $failed++ }
        }

        Write-PageCreationProgress -PageIndex $index -TotalPages $total -ElapsedSeconds $stopwatch.Elapsed.TotalSeconds `
            -Status $pageResult.Status -Leaf $leafName -ErrorMessage $pageResult.Message

        $results.Add($pageResult)
    }

    # Pages whose document has been deleted. Removing a .md leaves its page behind rendering
    # nothing, so a "fresh run" after retiring documents has to sweep them or the menu and search
    # keep offering empty pages.
    $orphaned = 0
    $emptyFolders = 0
    if ($RemoveOrphan) {
        $expected = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($document in $documents) {
            $leaf = [System.IO.Path]::GetFileNameWithoutExtension($document.Name)
            [void]$expected.Add((Get-MarkdownPageServerRelativeUrl -Folder $document.Folder -LeafName $leaf))
        }

        $rootSegment = Get-MarkdownPageFolderPath -Folder ""
        $rootMarker = if ([string]::IsNullOrWhiteSpace($rootSegment)) { "" } else { "/$rootSegment/" }
        foreach ($item in (Get-PnPListItem -List $config.SharePoint.pagesLibrary -PageSize 500)) {
            $fileRef = [string]$item.FieldValues.FileRef
            if ($fileRef -notlike "*.aspx") { continue }
            if ($rootMarker -and $fileRef -notlike "*$rootMarker*") { continue }
            if ($expected.Contains($fileRef)) { continue }

            if ($PSCmdlet.ShouldProcess($fileRef, "Recycle orphaned page")) {
                try {
                    Move-PnPListItemToRecycleBin -List $config.SharePoint.pagesLibrary -Identity $item.Id -Force -ErrorAction Stop | Out-Null
                    $orphaned++
                    Write-MarkstrataLog -Message "Orphan recycled (no Markdown document): $fileRef" -Component "MarkdownPage"
                } catch {
                    Write-MarkstrataLog -Message "Orphan sweep failed for '$fileRef': $($_.Exception.Message)" -Level Warning -Component "MarkdownPage"
                }
            }
        }
        if ($orphaned -gt 0) {
            Write-MarkstrataLog -Message "Orphan sweep: $orphaned page(s) recycled." -Component "MarkdownPage"
        }

        # Recycling the pages leaves their FOLDERS behind, so a retired category lingers in Site
        # Contents as an empty folder. Sweep those too, deepest first - removing a child can leave
        # its parent empty, and that parent has to be reconsidered in the same pass.
        $allItems = @(Get-PnPListItem -List $config.SharePoint.pagesLibrary -PageSize 1000)
        $folderItems = @($allItems | Where-Object { [int]$_.FieldValues.FSObjType -eq 1 })
        $filePaths = @($allItems | Where-Object { [int]$_.FieldValues.FSObjType -ne 1 } |
            ForEach-Object { [string]$_.FieldValues.FileDirRef })

        $candidateFolders = @($folderItems |
            Where-Object { $rootMarker -and ([string]$_.FieldValues.FileRef) -like "*$rootMarker*" } |
            Sort-Object { ([string]$_.FieldValues.FileRef -split "/").Count } -Descending)

        $removedPaths = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($folderItem in $candidateFolders) {
            $folderRef = [string]$folderItem.FieldValues.FileRef
            # Empty means: no file anywhere beneath it, and no surviving sub-folder.
            $holdsFile = @($filePaths | Where-Object { $_ -eq $folderRef -or $_ -like "$folderRef/*" }).Count -gt 0
            $holdsFolder = @($folderItems | Where-Object {
                    $childRef = [string]$_.FieldValues.FileRef
                    $childRef -like "$folderRef/*" -and -not $removedPaths.Contains($childRef)
                }).Count -gt 0
            if ($holdsFile -or $holdsFolder) { continue }

            if ($PSCmdlet.ShouldProcess($folderRef, "Recycle empty folder")) {
                try {
                    Move-PnPListItemToRecycleBin -List $config.SharePoint.pagesLibrary -Identity $folderItem.Id -Force -ErrorAction Stop | Out-Null
                    [void]$removedPaths.Add($folderRef)
                    $emptyFolders++
                    Write-MarkstrataLog -Message "Empty folder recycled: $folderRef" -Component "MarkdownPage"
                } catch {
                    Write-MarkstrataLog -Message "Folder sweep failed for '$folderRef': $($_.Exception.Message)" -Level Warning -Component "MarkdownPage"
                }
            }
        }
        if ($emptyFolders -gt 0) {
            Write-MarkstrataLog -Message "Folder sweep: $emptyFolders empty folder(s) recycled." -Component "MarkdownPage"
        }
    }

    $stopwatch.Stop()
    Write-Progress -Activity "Creating Markdown pages" -Completed
    Write-MarkstrataLog -Message ("Markdown pages complete: {0} created, {1} updated, {2} skipped, {3} failed in {4:mm\:ss}." -f $created, $updated, $skipped, $failed, $stopwatch.Elapsed) -Component "MarkdownPage"

    if ($PassThru) { return $results }

    return [pscustomobject]@{
        Documents = $total
        Created   = $created
        Updated   = $updated
        Skipped   = $skipped
        Failed    = $failed
        Orphaned  = $orphaned
        EmptyFolders = $emptyFolders
        Elapsed   = $stopwatch.Elapsed
    }
}
