function Update-MarkstrataNavigation {
    <#
    .SYNOPSIS
        Rebuild the site menu from the Markdown pages: Home, a themed group per top-level entry,
        and that group's categories beneath it.

    .DESCRIPTION
        Reads the pages that already exist under SitePages/<markdownPage.pageRootFolder>/ and
        rebuilds the menu around them. No wiki connection and no re-migration - run it whenever
        documents have been added, removed, moved or renamed and the pages rebuilt.

        The top level is a handful of short GROUP names from config/category-groups.json, not the
        categories themselves. Twenty categories do not fit across a SharePoint header bar: the bar
        shows four or five and pushes the rest into a "..." overflow where nobody finds them. Five
        groups fit, and each opens a mega menu of its categories.

            Home | Group One | Group Two | Group Three

        A group node is a LABEL, not a link: there is no "Group One" document, so the node is
        written with the linkless-header sentinel and only opens its children. A category node
        opens that category's index screen, which lists its documents - so the documents do not
        need to be in the menu at all. Set navigation.includePages to add them as a third level
        anyway.

        On a COMMUNICATION site the horizontal menu under the header is
        sourced from the QuickLaunch node collection, NOT TopNavigationBar. That is the default
        (navigation.location); TopNavigationBar is only right for a classic team site whose top
        bar is shown.

    .PARAMETER SetHomePage
        Also point the site's welcome page at the generated Markdown home index.

    .PARAMETER SkipPages
        Leave the per-document child nodes out even if navigation.includePages is on.

    .PARAMETER PassThru
        Emit the per-category detail instead of only the summary.

    .OUTPUTS
        PSCustomObject summary (Location, Categories, PageNodes, Skipped, HomePage, Elapsed).

    .EXAMPLE
        Connect-MarkstrataSite
        Update-MarkstrataNavigation -SetHomePage

        Rebuild the whole menu and make the Markdown home index the site's landing page.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [switch]$SetHomePage,

        [switch]$SkipPages,

        [switch]$PassThru
    )

    if (-not $script:SharePointReady) {
        throw "Not connected. Run Connect-MarkstrataSite first."
    }

    $config = Get-MarkstrataConfig
    $navigationConfig = $config.Navigation
    $navigationLocation = if (-not [string]::IsNullOrWhiteSpace((Get-OptionalProperty $navigationConfig "location" ""))) {
        [string]$navigationConfig.location
    } else { "QuickLaunch" }
    $includeHome  = [bool](Get-OptionalProperty $navigationConfig "includeHome" $true)
    $includePages = (-not $SkipPages) -and [bool](Get-OptionalProperty $navigationConfig "includePages" $true)
    $megaMenu     = [bool](Get-OptionalProperty $navigationConfig "megaMenu" $true)
    $useGroups    = [bool](Get-OptionalProperty $navigationConfig "useGroups" $true)

    $homeLeaf  = [System.IO.Path]::GetFileNameWithoutExtension([string]$config.MarkdownIndex.homeFileName)

    # An index is named after its own folder, so "is this the index?" is a per-folder question:
    # the document is the category's index when it sits directly in the category folder and its
    # leaf is that folder's index name.
    $isIndexDocument = {
        param($Leaf, $Folder, $CategoryFolder)
        if (-not $Folder -or $Folder -ne $CategoryFolder) { return $false }
        return $Leaf -eq [System.IO.Path]::GetFileNameWithoutExtension((Get-MarkdownIndexFileName -Folder $Folder))
    }

    # --- Collect the published Markdown pages ---------------------------------------------------
    $pagesLibrary = [string]$config.SharePoint.pagesLibrary
    $rootPrefix = (Get-MarkdownPageFolderPath -Folder "")
    $searchPrefix = if ([string]::IsNullOrWhiteSpace($rootPrefix)) { "" } else { "/$rootPrefix/" }

    $useRenderer = [bool](Get-OptionalProperty $navigationConfig "useRendererLinks" $false)
    $pages = [System.Collections.Generic.List[object]]::new()

    if ($useRenderer) {
        # Source the menu from the DOCUMENT LIBRARY, not from the pages that happen to exist.
        # Every entry points at the single renderer page with a strataDoc query string, so the menu
        # no longer depends on a page per document - which is what lets those pages be retired.
        $libraryUrl = ([string]$config.Markdown.libraryServerRelativeUrl).TrimEnd("/")
        foreach ($item in (Get-PnPListItem -List $config.Markdown.documentLibrary -PageSize 1000)) {
            $leafFile = [string]$item.FieldValues.FileLeafRef
            if ($leafFile -notlike "*.md") { continue }

            $reference = [string]$item.FieldValues.FileRef
            $marker = "$libraryUrl/"
            $markerIndex = $reference.IndexOf($marker, [StringComparison]::OrdinalIgnoreCase)
            if ($markerIndex -lt 0) { continue }
            $relative = $reference.Substring($markerIndex + $marker.Length)

            $folder = ""
            if ($relative.Contains("/")) { $folder = $relative.Substring(0, $relative.LastIndexOf("/")) }
            # A media folder holds no documents; skip anything that is not a real category.
            if ($folder -like "_*") { continue }

            $leaf = [System.IO.Path]::GetFileNameWithoutExtension($leafFile)
            $categoryFolder = if ($folder) { ($folder -split "/")[0] } else { "" }

            $pages.Add([pscustomobject]@{
                Leaf        = $leaf
                Folder      = $folder
                Category    = $categoryFolder
                Url         = (Get-MarkdownRendererUrl -Folder $folder -FileName $leafFile)
                IsIndex     = (& $isIndexDocument $leaf $folder $categoryFolder)
                IsHome      = ($leaf -eq $homeLeaf -and -not $folder)
                IsPublished = $true
            })
        }
    } else {
        $allItems = Get-PnPListItem -List $pagesLibrary -PageSize 500
        foreach ($item in $allItems) {
            $fileRef = [string]$item.FieldValues.FileRef
            if ($fileRef -notlike "*.aspx") { continue }
            if ($searchPrefix -and $fileRef -notlike "*$searchPrefix*") { continue }

            $leaf = [System.IO.Path]::GetFileNameWithoutExtension([string]$item.FieldValues.FileLeafRef)
            # Folder = everything between the page-root folder and the file name.
            $directory = [string]$item.FieldValues.FileDirRef
            $folder = ""
            $markerIndex = $directory.IndexOf($searchPrefix.TrimEnd("/"), [StringComparison]::OrdinalIgnoreCase)
            if ($searchPrefix -and $markerIndex -ge 0) {
                $folder = $directory.Substring($markerIndex + $searchPrefix.TrimEnd("/").Length).Trim("/")
            }

            # A draft page cannot be linked from navigation; record it rather than failing the build.
            $isPublished = ([string]$item.FieldValues._Level) -eq "1"

            # The TOP-LEVEL folder is the category; anything deeper (Alpha/Section/Subsection) is a section
            # inside it. Taking the whole path would turn every sub-folder into its own pseudo-category,
            # which no group knows about, so they would all pile into the default group.
            $categoryFolder = if ($folder) { ($folder -split "/")[0] } else { "" }

            $pages.Add([pscustomobject]@{
                Leaf        = $leaf
                Folder      = $folder
                Category    = $categoryFolder
                Url         = $fileRef
                IsIndex     = (& $isIndexDocument $leaf $folder $categoryFolder)
                IsHome      = ($leaf -eq $homeLeaf -and -not $folder)
                IsPublished = $isPublished
            })
        }
    }

    if ($pages.Count -eq 0) {
        throw "Nothing found to build a menu from. With useRendererLinks the source is the document library; otherwise run Publish-MarkstrataLibrary first."
    }

    $homePage = $pages | Where-Object { $_.IsHome } | Select-Object -First 1
    $documentPages = @($pages | Where-Object { -not $_.IsIndex -and -not $_.IsHome })
    $indexPages = @{}
    foreach ($indexPage in ($pages | Where-Object { $_.IsIndex })) { $indexPages[$indexPage.Category] = $indexPage }

    $folders = @($documentPages | ForEach-Object { $_.Category } | Where-Object { $_ } | Sort-Object -Unique)
    # @(): a single-category library would otherwise unwrap to a bare string (see the index command).
    $orderedFolders = @(Get-MarkdownCategoryOrder -FolderSlug $folders)

    if (-not $PSCmdlet.ShouldProcess($navigationLocation, "Rebuild navigation")) {
        return [pscustomobject]@{
            Location = $navigationLocation; Categories = $orderedFolders.Count
            PageNodes = $(if ($includePages) { $documentPages.Count } else { 0 })
            Skipped = 0; HomePage = $null; Elapsed = [TimeSpan]::Zero
        }
    }

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    # Mega menu renders the category -> documents hierarchy as columns, which is what makes a
    # 200-node menu usable. It is a SWITCH parameter - "-MegaMenuEnabled $true" silently binds wrong.
    if ($megaMenu) { Set-PnPWeb -MegaMenuEnabled:$true -ErrorAction SilentlyContinue }

    # Clear BOTH collections. Remove-PnPNavigationNode has no -Location parameter, and a single
    # sweep can leave stragglers behind (a silent partial clear is what piles up duplicates), so
    # re-fetch and remove until each location is genuinely empty.
    foreach ($location in @("QuickLaunch", "TopNavigationBar")) {
        $clearGuard = 0
        while ($clearGuard -lt 50) {
            $existingNodes = @(Get-PnPNavigationNode -Location $location -ErrorAction SilentlyContinue)
            if ($existingNodes.Count -eq 0) { break }
            foreach ($node in $existingNodes) { Remove-PnPNavigationNode -Identity $node.Id -Force -ErrorAction SilentlyContinue }
            $clearGuard++
        }
    }

    # Add-PnPNavigationNode SILENTLY TRUNCATES the URL at the path: both the "#fragment" and the
    # "?strataDoc=..." query string are dropped, so a node lands on the bare renderer page instead
    # of the document it names. Writing Url back onto the created node keeps the whole thing.
    $restoreNodeUrl = {
        param($NodeId, $FullUrl, $Label)
        if ($FullUrl -notmatch '[?#]') { return }
        try {
            $created = Get-PnPNavigationNode -Id $NodeId -ErrorAction Stop
            $created.Url = $FullUrl
            $created.Update()
            Invoke-PnPQuery -ErrorAction Stop
        } catch {
            Write-MarkstrataLog -Message "Could not restore the full URL on '$Label': $($_.Exception.Message)" -Level Warning -Component "Navigation" -NoConsole
        }
    }

    if ($includeHome -and $homePage) {
        $homeNode = Add-PnPNavigationNode -Location $navigationLocation -Title "Home" -Url $homePage.Url -ErrorAction SilentlyContinue
        if ($homeNode) { & $restoreNodeUrl $homeNode.Id $homePage.Url "Home" }
    }

    $details = [System.Collections.Generic.List[object]]::new()
    # A scriptblock cannot assign to a parent local, but it can mutate an object the
    # parent holds - so the skip counter lives in a hashtable rather than module scope.
    $counters = @{ Skipped = 0 }

    # Resolve each category's node once: title, destination, and the documents beneath it.
    $categoryUrlFor = {
        param($Folder)
        # The category node opens that category's index screen; without one, fall back to the
        # first document so the node still goes somewhere real.
        if ($indexPages.ContainsKey($Folder)) { return $indexPages[$Folder].Url }
        return ($documentPages | Where-Object { $_.Category -eq $Folder } | Select-Object -First 1).Url
    }

    $addCategoryNode = {
        param($Folder, $ParentId)
        $displayName = Get-MarkdownCategoryDisplayName -FolderSlug $Folder
        $categoryUrl = & $categoryUrlFor $Folder

        $arguments = @{ Location = $navigationLocation; Title = $displayName; Url = $categoryUrl; ErrorAction = "Stop" }
        if ($ParentId) { $arguments["Parent"] = $ParentId }
        $node = Add-PnPNavigationNode @arguments
        & $restoreNodeUrl $node.Id $categoryUrl $displayName

        $added = 0
        if ($includePages) {
            foreach ($categoryPage in @($documentPages | Where-Object { $_.Category -eq $Folder } | Sort-Object Folder, Leaf)) {
                if (-not $categoryPage.IsPublished) {
                    $counters.Skipped++
                    Write-MarkstrataLog -Message "Nav skip '$($categoryPage.Leaf)': page is an unpublished draft." -Level Warning -Component "Navigation" -NoConsole
                    continue
                }
                try {
                    $childNode = Add-PnPNavigationNode -Location $navigationLocation -Title $categoryPage.Leaf -Url $categoryPage.Url -Parent $node.Id -ErrorAction Stop
                    & $restoreNodeUrl $childNode.Id $categoryPage.Url $categoryPage.Leaf
                    $added++
                } catch {
                    $counters.Skipped++
                    Write-MarkstrataLog -Message "Nav skip '$($categoryPage.Leaf)': $($_.Exception.Message)" -Level Warning -Component "Navigation" -NoConsole
                }
            }
        }
        $details.Add([pscustomobject]@{ Category = $displayName; Folder = $Folder; Url = $categoryUrl; Pages = $added })
    }


    if ($useGroups) {
        # Top level is a handful of short group names, because twenty categories do not fit across
        # the header bar - SharePoint pushes the rest into the "..." overflow where nobody sees them.
        $displayByFolder = @{}
        foreach ($folder in $orderedFolders) { $displayByFolder[(Get-MarkdownCategoryDisplayName -FolderSlug $folder)] = $folder }
        $groups = @(Get-MarkstrataCategoryGroup -Category @($displayByFolder.Keys))

        $pageNodeCount = if ($includePages) { $documentPages.Count } else { 0 }
        Write-MarkstrataLog -Message "Building navigation ($navigationLocation): $($groups.Count) groups + $($orderedFolders.Count) categories + $pageNodeCount page nodes." -Component "Navigation"

        $groupNumber = 0
        foreach ($group in $groups) {
            $groupNumber++
            # A group is a HOLDER, not a destination: a group name is not a document and has no
            # page of its own, so it must not be clickable. "http://linkless.header/" is the
            # sentinel SharePoint itself writes when you add a Label in the navigation editor - it
            # renders the node as plain text that only opens its children.
            $groupUrl = $script:LinklessHeaderUrl

            Write-Progress -Activity "Rebuilding navigation menu" `
                -Status "[$groupNumber/$($groups.Count)] $($group.Name) (+$($group.Categories.Count) categories)" `
                -PercentComplete ([int](($groupNumber / [Math]::Max(1, $groups.Count)) * 100))
            Write-MarkstrataLog -Message "Nav [$groupNumber/$($groups.Count)] $($group.Name): +$($group.Categories.Count) categories." -Component "Navigation"

            $groupNode = Add-PnPNavigationNode -Location $navigationLocation -Title $group.Name -Url $groupUrl -ErrorAction Stop
            foreach ($categoryName in $group.Categories) {
                & $addCategoryNode $displayByFolder[$categoryName] $groupNode.Id
            }
        }
    } else {
        $pageNodeCount = if ($includePages) { $documentPages.Count } else { 0 }
        Write-MarkstrataLog -Message "Building navigation ($navigationLocation): $($orderedFolders.Count) categories + $pageNodeCount page nodes." -Component "Navigation"

        $categoryNumber = 0
        foreach ($folder in $orderedFolders) {
            $categoryNumber++
            Write-Progress -Activity "Rebuilding navigation menu" `
                -Status "[$categoryNumber/$($orderedFolders.Count)] $folder" `
                -PercentComplete ([int](($categoryNumber / [Math]::Max(1, $orderedFolders.Count)) * 100))
            & $addCategoryNode $folder $null
        }
    }
    $skipped = $counters.Skipped
    Write-Progress -Activity "Rebuilding navigation menu" -Completed

    $footerPruned = 0
    if ([bool](Get-OptionalProperty $navigationConfig "pruneFooter" $true)) {
        $footerPruned = Remove-StaleFooterNode
    }

    $homePageSet = $null
    if ($SetHomePage -and $homePage) {
        try {
            # Set-PnPHomePage takes a path relative to the WEB, not a server-relative URL.
            $webRelative = $homePage.Url
            $siteRoot = Get-MarkstrataSiteRelativeRoot
            if ($siteRoot -and $webRelative.StartsWith($siteRoot, [StringComparison]::OrdinalIgnoreCase)) {
                $webRelative = $webRelative.Substring($siteRoot.Length).Trim("/")
            }
            Set-PnPHomePage -RootFolderRelativeUrl $webRelative -ErrorAction Stop
            $homePageSet = $webRelative
            Write-MarkstrataLog -Message "Site home page set to $webRelative." -Component "Navigation"
        } catch {
            Write-MarkstrataLog -Message "Could not set the home page: $($_.Exception.Message)" -Level Warning -Component "Navigation"
        }
    } elseif ($SetHomePage) {
        Write-MarkstrataLog -Message "No home index page found - run New-MarkstrataIndex and Publish-MarkstrataLibrary first." -Level Warning -Component "Navigation"
    }

    $stopwatch.Stop()
    $summaryDetail = "$($orderedFolders.Count) categories"
    if ($includePages) { $summaryDetail += " + $(($details | Measure-Object Pages -Sum).Sum) page nodes" }
    if ($skipped -gt 0) { $summaryDetail += " ($skipped skipped)" }
    Write-MarkstrataLog -Message ("Navigation rebuilt: {0} in {1:mm\:ss}." -f $summaryDetail, $stopwatch.Elapsed) -Component "Navigation"

    if ($PassThru) { return $details }

    return [pscustomobject]@{
        Location     = $navigationLocation
        Categories   = $orderedFolders.Count
        PageNodes    = ($details | Measure-Object Pages -Sum).Sum
        Skipped      = $skipped
        FooterPruned = $footerPruned
        HomePage     = $homePageSet
        Elapsed      = $stopwatch.Elapsed
    }
}
