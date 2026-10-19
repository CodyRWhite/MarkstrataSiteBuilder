function Invoke-MarkstrataRefresh {
    <#
    .SYNOPSIS
        One-call refresh after documents have been added, edited, retired, moved or renamed:
        indexes, waits for sync, the renderer page, the menu.

    .DESCRIPTION
        The steps have to run in this order, and each depends on the one before:

          1. New-MarkstrataIndex         - regenerate the home index and every category index from
                                           what is actually in the local library folder.
          2. Wait for OneDrive           - the renderer serves documents out of the LIBRARY, not the
                                           local folder, so nothing is worth rebuilding until the
                                           sync lands.
          3. New-MarkstrataRenderer      - the single page that serves every document.
          4. Update-MarkstrataNavigation - rebuild the menu from the documents that now exist.

        Step 2 is the one that is easy to get wrong by hand: a menu rebuilt before the sync lands
        points at documents SharePoint does not have yet.

        This used to run Publish-MarkstrataLibrary -RemoveOrphan instead of step 3 - a page per
        document, plus a sweep of the pages whose document had gone. On a site using the single
        renderer that rebuilt the very tree the renderer exists to replace, which is not what a
        command called "refresh" should do to a site. Publish-MarkstrataLibrary is still there for
        anyone who wants those pages, and Publish-MarkstrataLibrary -OrphanOnly still sweeps them.

    .PARAMETER LibraryRoot
        Local root of the synced document library. Defaults to markdown.libraryRoot.

    .PARAMETER SyncTimeoutMinutes
        How long to wait for the local folder and the library to agree before giving up. Default 15.
        On timeout the run stops BEFORE publishing rather than building pages against a half-synced
        library.

    .PARAMETER SkipIndex
        Do not regenerate the index screens (use the ones already in the library).

    .PARAMETER SkipNavigation
        Rebuild everything else but leave the menu alone.

    .PARAMETER SkipRenderer
        Leave the renderer page alone. It serves whatever documents exist, so a library that has
        only gained or lost documents does not need it rebuilt at all.

    .PARAMETER SetHomePage
        Also point the site's welcome page at the renderer. NOT done by default: which page a site
        lands on is a deliberate choice, and a routine refresh has no business changing it. Pass
        this the first time, or after moving the renderer.

    .PARAMETER Force
        Recreate the renderer page even if it already exists.

    .OUTPUTS
        PSCustomObject with Index, Renderer and Navigation results, plus Elapsed.

    .EXAMPLE
        Connect-MarkstrataSite
        Invoke-MarkstrataRefresh

        The whole refresh after a round of editing and retiring documents: indexes, the renderer,
        the menu. Nothing about the site's style or landing page is touched.

    .EXAMPLE
        Invoke-MarkstrataRefresh -WhatIf

        Show what each stage would do without writing anything.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [string]$LibraryRoot,

        [int]$SyncTimeoutMinutes = 15,

        [switch]$SkipIndex,

        [switch]$SkipNavigation,

        [switch]$SkipRenderer,

        [switch]$SetHomePage,

        [switch]$Force
    )

    if (-not $script:SharePointReady) {
        throw "Not connected. Run Connect-MarkstrataSite first."
    }

    $config = Get-MarkstrataConfig
    if ([string]::IsNullOrWhiteSpace($LibraryRoot)) { $LibraryRoot = [string]$config.Markdown.libraryRoot }
    if (-not (Test-Path -LiteralPath $LibraryRoot)) {
        throw "Markdown library root not found: $LibraryRoot"
    }

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $indexResult = $null
    $rendererResult = $null
    $navigationResult = $null

    # --- 1. Index screens ---------------------------------------------------------------------
    if (-not $SkipIndex) {
        Write-MarkstrataLog -Message "Refresh 1/4: regenerating index screens." -Component "Refresh"
        $indexResult = New-MarkstrataIndex -LibraryRoot $LibraryRoot
    }

    # --- 2. Wait for the sync -----------------------------------------------------------------
    # Compare the two sides by relative path. The library is authoritative for publishing, so a
    # mismatch means OneDrive is still working and anything published now would be wrong.
    $documentExtensions = Get-MarkstrataDocumentExtension
    $localPaths = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    # -Filter takes one pattern, and a library may hold more than one extension, so the filtering
    # happens here rather than in the provider.
    foreach ($file in (Get-ChildItem -LiteralPath $LibraryRoot -Recurse -File |
            Where-Object { Test-MarkstrataDocumentFile -Name $_.Name -Extension $documentExtensions })) {
        $relative = $file.FullName.Substring($LibraryRoot.Length).TrimStart("\", "/") -replace "\\", "/"
        [void]$localPaths.Add($relative)
    }

    $librarySiteRelative = ([string]$config.Markdown.libraryServerRelativeUrl).TrimEnd("/")
    $siteRoot = Get-MarkstrataSiteRelativeRoot
    if ($siteRoot -and $librarySiteRelative.StartsWith($siteRoot, [StringComparison]::OrdinalIgnoreCase)) {
        $librarySiteRelative = $librarySiteRelative.Substring($siteRoot.Length)
    }
    $librarySiteRelative = $librarySiteRelative.Trim("/")

    $getLibraryPaths = {
        $set = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($item in (Get-PnPListItem -List $config.Markdown.documentLibrary -PageSize 1000 -ErrorAction SilentlyContinue)) {
            $leaf = [string]$item.FieldValues.FileLeafRef
            if (-not (Test-MarkstrataDocumentFile -Name $leaf -Extension $documentExtensions)) { continue }
            $reference = [string]$item.FieldValues.FileRef
            $marker = "/$librarySiteRelative/"
            $markerIndex = $reference.IndexOf($marker, [StringComparison]::OrdinalIgnoreCase)
            if ($markerIndex -lt 0) { continue }
            [void]$set.Add($reference.Substring($markerIndex + $marker.Length))
        }
        return $set
    }

    # Under -WhatIf there is nothing to wait for: the later stages report their plans without
    # writing, so waiting on a sync that does not matter would just stall the preview.
    $waitForSync = $PSCmdlet.ShouldProcess("OneDrive sync of $LibraryRoot", "Wait for the library to match the local folder")
    if (-not $waitForSync) {
        Write-MarkstrataLog -Message "Refresh 2/4: skipping the sync wait (preview only)." -Component "Refresh"
    }

    if ($waitForSync) {
        Write-MarkstrataLog -Message "Refresh 2/4: waiting for OneDrive to sync $($localPaths.Count) document(s) to the library." -Component "Refresh"
    }
    $syncDeadline = (Get-Date).AddMinutes($SyncTimeoutMinutes)
    $synced = -not $waitForSync
    $missing = @()
    while ($waitForSync -and (Get-Date) -lt $syncDeadline) {
        $libraryPaths = & $getLibraryPaths
        $missing = @($localPaths | Where-Object { -not $libraryPaths.Contains($_) })
        $extra = @($libraryPaths | Where-Object { -not $localPaths.Contains($_) })
        if ($missing.Count -eq 0 -and $extra.Count -eq 0) { $synced = $true; break }

        Write-MarkstrataLog -Message "Sync pending: $($missing.Count) not yet uploaded, $($extra.Count) not yet removed." -Component "Refresh"
        Start-Sleep -Seconds 20
    }

    if (-not $synced) {
        $detail = if ($missing.Count -gt 0) { " Still missing from the library: $(($missing | Select-Object -First 5) -join ', ')" } else { "" }
        throw ("OneDrive has not finished syncing after $SyncTimeoutMinutes minute(s); stopping before publishing so pages are not built against a half-synced library.$detail")
    }
    if ($waitForSync) {
        Write-MarkstrataLog -Message "Sync complete: local folder and library agree." -Component "Refresh"
    }

    # --- 3. The renderer -----------------------------------------------------------------------
    # One page serves every document, so this is a no-op on a site that already has it - which is
    # why -SkipRenderer exists for the common case of documents having only come and gone.
    if (-not $SkipRenderer) {
        Write-MarkstrataLog -Message "Refresh 3/4: checking the renderer page." -Component "Refresh"
        $rendererArguments = @{}
        if ($Force)       { $rendererArguments["Force"] = $true }
        if ($SetHomePage) { $rendererArguments["SetHomePage"] = $true }
        $rendererResult = New-MarkstrataRenderer @rendererArguments
    }

    # --- 4. Menu -------------------------------------------------------------------------------
    # Not -SetHomePage: that pointed the welcome page at the generated home INDEX page, which on
    # this model may not exist, and changing which page a site lands on is not a refresh's business.
    # Step 3 sets it when asked, to the renderer.
    if (-not $SkipNavigation) {
        Write-MarkstrataLog -Message "Refresh 4/4: rebuilding the menu." -Component "Refresh"
        $navigationResult = Update-MarkstrataNavigation
    }

    $stopwatch.Stop()
    Write-MarkstrataLog -Message ("Refresh complete in {0:hh\:mm\:ss}." -f $stopwatch.Elapsed) -Component "Refresh"

    return [pscustomobject]@{
        Index      = $indexResult
        Renderer   = $rendererResult
        Navigation = $navigationResult
        Elapsed    = $stopwatch.Elapsed
    }
}
