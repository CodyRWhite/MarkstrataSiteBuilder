function Remove-MarkstrataLegacyPage {
    <#
    .SYNOPSIS
        Delete the site pages left behind by the HTML pipeline, keeping everything under the
        Markdown page root.

    .DESCRIPTION
        Once every document is served by a Markdown page, the pages the HTML pipeline created are
        dead weight: they duplicate the content, they compete in search, and they make the Site
        Pages library impossible to read. This removes them.

        What counts as legacy is defined by exclusion, not by a list: every .aspx in the pages
        library that is NOT under SitePages/<markdownPage.pageRootFolder>/. That way a page added
        by hand outside the Markdown tree is caught too, and nothing the current pipeline produced
        can ever be caught.

        Three guards, because this is destructive:

          * The site's current welcome page is never deleted. Re-point the home page first
            (Update-MarkstrataNavigation -SetHomePage), or this leaves the site landing on a
            page that no longer exists.
          * Pages under the Markdown page root are never considered.
          * Deletion is a RECYCLE, not a permanent delete - items land in the site recycle bin and
            can be restored for 93 days.

    .PARAMETER Keep
        Leaf names (with or without .aspx) to preserve, for example a hand-built reference page.
        Matched case-insensitively against the file name.

    .PARAMETER IncludePageRoot
        Also remove the pages UNDER the page root. Once the single renderer page serves the whole
        library through a strataDoc query string, a page per document is redundant - this is what
        retires them. The renderer itself and the site's welcome page are never removed.

    .PARAMETER Force
        Delete without the per-run confirmation prompt. -WhatIf still wins.

    .PARAMETER PassThru
        Emit one object per page instead of only the summary.

    .OUTPUTS
        Summary PSCustomObject (Examined, Deleted, Kept, Failed), or per-page objects with
        -PassThru.

    .EXAMPLE
        Remove-MarkstrataLegacyPage -WhatIf

        List every page that would be deleted, touching nothing.

    .EXAMPLE
        Remove-MarkstrataLegacyPage -Keep "Hand-Built-Page.aspx" -Force

        Delete the legacy pages but preserve the hand-built reference page.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = "High")]
    [OutputType([pscustomobject])]
    param(
        [string[]]$Keep = @(),

        [switch]$IncludePageRoot,

        [switch]$Force,

        [switch]$PassThru
    )

    if (-not $script:SharePointReady) {
        throw "Not connected. Run Connect-MarkstrataSite first."
    }

    # ConfirmImpact is High, so ShouldProcess prompts by default - and a prompt is fatal in a
    # non-interactive host. -Force is the caller saying "don't ask", so lower the preference for
    # this scope only; an explicit -Confirm still wins, and -WhatIf is unaffected.
    if ($Force -and -not $PSBoundParameters.ContainsKey("Confirm")) {
        $ConfirmPreference = "None"
    }

    $config = Get-MarkstrataConfig
    $pagesLibrary = [string]$config.SharePoint.pagesLibrary
    $rootPrefix = Get-MarkdownPageFolderPath -Folder ""
    if ([string]::IsNullOrWhiteSpace($rootPrefix) -and -not $IncludePageRoot) {
        throw "markdownPage.pageRootFolder is empty, so every page would count as legacy. Refusing to run."
    }
    $protectedPrefix = "/$rootPrefix/"

    # The renderer serves every document through a strataDoc query string, so it must survive a
    # sweep that retires the per-document pages.
    $rendererLeaf = [string](Get-OptionalProperty $config.MarkdownPage "rendererPage" "Wiki.aspx")

    # Never delete the page the site currently lands on. Compared as a FULL server-relative path,
    # not by leaf name: the welcome page is "SitePages/Docs/Home.aspx" and a legacy
    # "SitePages/Home.aspx" shares its leaf, so a leaf comparison would spare the wrong page too.
    $welcomePage = ""
    try { $welcomePage = [string](Get-PnPWeb -Includes WelcomePage).WelcomePage } catch { $welcomePage = "" }
    $welcomeUrl = ""
    if ($welcomePage) {
        $welcomeUrl = "{0}/{1}" -f (Get-MarkstrataSiteRelativeRoot), $welcomePage.TrimStart("/")
    }

    $keepLeaves = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($keepName in $Keep) {
        if ([string]::IsNullOrWhiteSpace($keepName)) { continue }
        [void]$keepLeaves.Add($keepName)
        [void]$keepLeaves.Add(($keepName -replace '\.aspx$', ''))
        [void]$keepLeaves.Add("$($keepName -replace '\.aspx$', '').aspx")
    }

    $candidates = [System.Collections.Generic.List[object]]::new()
    foreach ($item in (Get-PnPListItem -List $pagesLibrary -PageSize 500)) {
        $fileRef = [string]$item.FieldValues.FileRef
        if ($fileRef -notlike "*.aspx") { continue }
        if (-not $IncludePageRoot -and $fileRef -like "*$protectedPrefix*") { continue }

        $leaf = [string]$item.FieldValues.FileLeafRef
        $reason = ""
        if ($keepLeaves.Contains($leaf)) { $reason = "Kept (-Keep)" }
        elseif ($welcomeUrl -and $fileRef -eq $welcomeUrl) { $reason = "Kept (current home page)" }
        elseif ($leaf -eq $rendererLeaf) { $reason = "Kept (renderer page)" }

        $candidates.Add([pscustomobject]@{
            # The list item ID, captured here: Move-PnPListItemToRecycleBin -Identity takes an ID
            # (or item object), and handing it a server-relative URL fails with a null reference.
            Id     = [int]$item.Id
            Name   = $leaf
            Url    = $fileRef
            Action = $(if ($reason) { $reason } else { "Delete" })
        })
    }

    $toDelete = @($candidates | Where-Object { $_.Action -eq "Delete" })
    $kept     = @($candidates | Where-Object { $_.Action -ne "Delete" })

    Write-MarkstrataLog -Message "Legacy sweep: $($candidates.Count) page(s) outside /$rootPrefix/; $($toDelete.Count) to delete, $($kept.Count) kept." -Component "Cleanup"
    foreach ($keptPage in $kept) {
        Write-MarkstrataLog -Message "$($keptPage.Action): $($keptPage.Url)" -Component "Cleanup"
    }

    if ($toDelete.Count -eq 0) {
        return [pscustomobject]@{ Examined = $candidates.Count; Deleted = 0; Kept = $kept.Count; Failed = 0 }
    }

    # -WhatIf must never prompt: the per-item ShouldProcess below already reports the plan, and a
    # bulk prompt during a preview is both wrong and fatal in a non-interactive host.
    if (-not $Force -and -not $WhatIfPreference) {
        # ${pagesLibrary}, not $pagesLibrary: "?" is a legal character in a PowerShell variable
        # name, so "$pagesLibrary?" parses as a variable of that name and throws under StrictMode.
        $prompt = "Recycle $($toDelete.Count) legacy page(s) from ${pagesLibrary}? They can be restored from the site recycle bin for 93 days."
        $proceed = $false
        try {
            $proceed = $PSCmdlet.ShouldContinue($prompt, "Remove legacy pages")
        } catch {
            throw "This session cannot prompt for confirmation. Re-run with -WhatIf to preview, or -Force to proceed: $($_.Exception.Message)"
        }
        if (-not $proceed) {
            Write-MarkstrataLog -Message "Legacy sweep cancelled by the operator." -Level Warning -Component "Cleanup"
            return [pscustomobject]@{ Examined = $candidates.Count; Deleted = 0; Kept = $kept.Count; Failed = 0 }
        }
    }

    $results = [System.Collections.Generic.List[object]]::new()
    $deleted = 0; $failed = 0; $index = 0
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    foreach ($page in $toDelete) {
        $index++
        if (-not $PSCmdlet.ShouldProcess($page.Url, "Recycle legacy page")) {
            $results.Add([pscustomobject]@{ Name = $page.Name; Url = $page.Url; Status = "WhatIf" })
            continue
        }
        try {
            # Recycle, not delete: recoverable from the site recycle bin. -Identity is the list
            # item ID; a server-relative URL is accepted by the parameter binder but fails inside
            # the cmdlet with a bare "Object reference not set to an instance of an object".
            Move-PnPListItemToRecycleBin -List $pagesLibrary -Identity $page.Id -Force -ErrorAction Stop | Out-Null
            $deleted++
            $results.Add([pscustomobject]@{ Name = $page.Name; Url = $page.Url; Status = "Recycled" })
        } catch {
            $failed++
            $results.Add([pscustomobject]@{ Name = $page.Name; Url = $page.Url; Status = "Failed"; Message = $_.Exception.Message })
            Write-MarkstrataLog -Message "Delete failed for '$($page.Url)': $($_.Exception.Message)" -Level Error -Component "Cleanup"
        }
        Write-Progress -Activity "Removing legacy pages" -Status "$index of $($toDelete.Count)" `
            -PercentComplete ([int](100 * $index / $toDelete.Count))
    }
    Write-Progress -Activity "Removing legacy pages" -Completed
    $stopwatch.Stop()

    Write-MarkstrataLog -Message ("Legacy sweep complete: {0} recycled, {1} kept, {2} failed in {3:mm\:ss}." -f $deleted, $kept.Count, $failed, $stopwatch.Elapsed) -Component "Cleanup"

    if ($PassThru) { return $results }

    return [pscustomobject]@{
        Examined = $candidates.Count
        Deleted  = $deleted
        Kept     = $kept.Count
        Failed   = $failed
    }
}
