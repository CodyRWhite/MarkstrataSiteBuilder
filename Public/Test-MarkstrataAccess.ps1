function Test-MarkstrataAccess {
    <#
    .SYNOPSIS
        Check that everything the builder needs is present and reachable, changing nothing.

    .DESCRIPTION
        Run this before the first publish, and whenever a run fails in a way that might be
        permissions. It is read-only: no page, folder or list item is created.

        What it checks, in the order that makes a failure easiest to read:

          Connection    which mode the session is using, and which site it reached
          Write access  effective permissions on the web, because a read-only connection fails
                        late and confusingly - halfway through a publish rather than at the start
          Pages library the library the renderer page is created in
          Documents     the Markdown library, its server-relative path, and how many .md files
                        SharePoint can currently see
          Local library the folder on this machine, if one is configured
          Web part      whether the Markstrata component is registered in the tenant app
                        catalogue, since a page built without it renders an empty canvas

        Each check is reported separately and a failure in one does not stop the others, so a
        single run tells you everything that is wrong rather than the first thing.

    .OUTPUTS
        PSCustomObject with Ok, Site, Mode, DocumentCount, and Checks (one entry per check with
        Name, Status and Detail).

    .EXAMPLE
        Test-MarkstrataAccess

    .EXAMPLE
        (Test-MarkstrataAccess).Checks | Format-Table Name, Status, Detail

        The full detail, one row per check.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()

    if (-not $script:SharePointReady) {
        throw "Not connected. Run Connect-MarkstrataSite first."
    }

    $config = Get-MarkstrataConfig
    $checks = [System.Collections.Generic.List[object]]::new()
    $documentCount = 0

    $record = {
        param($Name, $Status, $Detail)
        $checks.Add([pscustomobject]@{ Name = $Name; Status = $Status; Detail = $Detail })
    }

    # ---- Connection ---------------------------------------------------------------------------
    $siteTitle = ""
    try {
        $web = Get-PnPWeb -ErrorAction Stop
        $siteTitle = $web.Title
        & $record "Connection" "Pass" ("$($web.Title) ($($web.ServerRelativeUrl)), $script:ConnectionMode")
    }
    catch {
        & $record "Connection" "Fail" $_.Exception.Message
    }

    # ---- Write access -------------------------------------------------------------------------
    # Checked by reading effective permissions rather than by creating something: a probe item in
    # a documentation library is litter, and a failed cleanup would leave it there permanently.
    try {
        $permissions = (Get-PnPWeb -Includes EffectiveBasePermissions -ErrorAction Stop).EffectiveBasePermissions
        $canAdd = $permissions.Has([Microsoft.SharePoint.Client.PermissionKind]::AddListItems)
        if ($canAdd) {
            & $record "Write access" "Pass" "AddListItems is granted."
        }
        else {
            & $record "Write access" "Fail" "AddListItems is NOT granted; a publish would fail partway through. For an app-only connection, check the site grant (Register-MarkstrataApp -Unattended)."
        }
    }
    catch {
        & $record "Write access" "Fail" $_.Exception.Message
    }

    # ---- Pages library ------------------------------------------------------------------------
    try {
        $pagesLibrary = Get-PnPList -Identity $config.SharePoint.pagesLibrary -ErrorAction Stop
        & $record "Pages library" "Pass" "'$($pagesLibrary.Title)' holds $($pagesLibrary.ItemCount) item(s)."
    }
    catch {
        & $record "Pages library" "Fail" "'$($config.SharePoint.pagesLibrary)' - $($_.Exception.Message)"
    }

    # ---- Document library ---------------------------------------------------------------------
    try {
        $libraryTitle = [string]$config.Markdown.documentLibrary
        $documents = @(Get-PnPListItem -List $libraryTitle -PageSize 1000 -ErrorAction Stop |
            Where-Object { [string]$_.FieldValues.FileLeafRef -like "*.md" })
        $documentCount = $documents.Count
        if ($documentCount -eq 0) {
            & $record "Document library" "Warn" "'$libraryTitle' is reachable but holds no .md files yet."
        }
        else {
            & $record "Document library" "Pass" "'$libraryTitle' holds $documentCount Markdown document(s)."
        }
    }
    catch {
        & $record "Document library" "Fail" "'$($config.Markdown.documentLibrary)' - $($_.Exception.Message)"
    }

    # The server-relative URL is what every generated link is built from, so a mismatch here is the
    # cause of a site full of links that resolve to nothing.
    $libraryUrl = [string](Get-OptionalProperty $config.Markdown "libraryServerRelativeUrl" "")
    if ([string]::IsNullOrWhiteSpace($libraryUrl)) {
        & $record "Library path" "Fail" "markdown.libraryServerRelativeUrl is not set. Run Initialize-MarkstrataConfig."
    }
    else {
        try {
            Get-PnPFolder -Url $libraryUrl -ErrorAction Stop | Out-Null
            & $record "Library path" "Pass" $libraryUrl
        }
        catch {
            & $record "Library path" "Fail" "$libraryUrl - $($_.Exception.Message)"
        }
    }

    # ---- Local library ------------------------------------------------------------------------
    $libraryRoot = [string](Get-OptionalProperty $config.Markdown "libraryRoot" "")
    if ([string]::IsNullOrWhiteSpace($libraryRoot)) {
        & $record "Local library" "Warn" "markdown.libraryRoot is not set. Index generation and link conversion work on local files and need it."
    }
    elseif (Test-Path -LiteralPath $libraryRoot) {
        $localCount = @(Get-ChildItem -LiteralPath $libraryRoot -Filter "*.md" -File -Recurse -ErrorAction SilentlyContinue).Count
        & $record "Local library" "Pass" "$libraryRoot holds $localCount Markdown document(s)."
    }
    else {
        & $record "Local library" "Fail" "$libraryRoot does not exist on this machine."
    }

    # ---- The web part -------------------------------------------------------------------------
    # A page built without the component renders an empty canvas and reports nothing, so this is
    # worth knowing before publishing rather than after.
    try {
        $componentId = [string]$config.MarkdownPage.componentId
        $component = @(Get-PnPAvailableClientSideComponent -ErrorAction Stop) |
            Where-Object { $_.Id -like "*$componentId*" } | Select-Object -First 1
        if ($component) {
            & $record "Markstrata web part" "Pass" "'$($component.Name)' is available on this site."
        }
        else {
            & $record "Markstrata web part" "Fail" "Component $componentId is not available here. Install the Markstrata package in the tenant app catalogue and add it to this site."
        }
    }
    catch {
        & $record "Markstrata web part" "Warn" "Could not enumerate the site's components: $($_.Exception.Message)"
    }

    foreach ($check in $checks) {
        $level = switch ($check.Status) { "Fail" { "Error" } "Warn" { "Warning" } default { "Info" } }
        Write-MarkstrataLog ("{0,-20} {1,-5} {2}" -f $check.Name, $check.Status, $check.Detail) -Level $level
    }

    return [pscustomobject]@{
        Ok            = (@($checks | Where-Object { $_.Status -eq "Fail" }).Count -eq 0)
        Site          = $siteTitle
        Mode          = $script:ConnectionMode
        DocumentCount = $documentCount
        Checks        = $checks
    }
}
