function Update-MarkstrataPageSetting {
    <#
    .SYNOPSIS
        Push the Markdown web part's rendering settings out to every page, without rebuilding them.

    .DESCRIPTION
        The template page (Docs/Home.aspx) is where rendering options are chosen by hand; this
        copies them to every other page.

        It is a PROPERTY EDIT, not a rebuild. Publish-MarkstrataLibrary recreates each page - add the
        page, add the web part, set the title, publish - which is roughly six round trips each and
        around twenty minutes across the library. Here each page is one read and one write, so the
        same change lands in a couple of minutes. Nothing about the page other than the web part's
        properties is touched.

        The four per-page keys are preserved from each page's EXISTING properties, never copied
        from the template: contentSource, selectedLibrary, selectedFolder, selectedFile and its
        cached fileMetadata. Copying those from the template would repoint every page at the
        template's own document.

    .PARAMETER FromPage
        Page to take the settings from, relative to the pages library. Defaults to the home index
        (markdownIndex.homeFileName under the page root), which is the template by convention.

    .PARAMETER UpdateConfig
        Also write the settings back into config/MarkstrataSiteBuilder.config.json, so pages
        built later start out matching. Without this the config drifts behind the site.

    .PARAMETER PassThru
        Emit one object per page instead of only the summary.

    .OUTPUTS
        PSCustomObject summary (Source, Applied, Unchanged, Failed, Properties, Elapsed).

    .EXAMPLE
        Update-MarkstrataPageSetting -WhatIf

        Show which pages would change, and how many properties differ.

    .EXAMPLE
        Update-MarkstrataPageSetting -UpdateConfig

        Push the template's settings to every page and record them in config.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [string]$FromPage,

        [switch]$UpdateConfig,

        [switch]$PassThru
    )

    if (-not $script:SharePointReady) {
        throw "Not connected. Run Connect-MarkstrataSite first."
    }

    $config = Get-MarkstrataConfig
    $pagesLibrary = [string]$config.SharePoint.pagesLibrary
    $rootFolder = Get-MarkdownPageFolderPath -Folder ""
    $homeLeaf = [System.IO.Path]::GetFileNameWithoutExtension([string]$config.MarkdownIndex.homeFileName)

    if ([string]::IsNullOrWhiteSpace($FromPage)) {
        $FromPage = if ($rootFolder) { "$rootFolder/$homeLeaf.aspx" } else { "$homeLeaf.aspx" }
    }

    # These describe WHICH document a page renders; they belong to the page, not the template.
    $perPageKeys = @("contentSource", "selectedLibrary", "selectedFolder", "selectedFile", "fileMetadata", "fileUrl")

    $templatePage = Get-PnPPage -Identity $FromPage -ErrorAction Stop
    $templateControl = $templatePage.Sections[0].Controls[0]
    $templateProperties = $templateControl.PropertiesJson | ConvertFrom-Json

    $rendering = [ordered]@{}
    foreach ($property in ($templateProperties.PSObject.Properties | Sort-Object Name)) {
        if ($property.Name -in $perPageKeys) { continue }
        $rendering[$property.Name] = $property.Value
    }
    Write-MarkstrataLog -Message "Template '$FromPage' contributes $($rendering.Count) rendering property(ies)." -Component "PageSetting"

    # Collect the pages to update.
    $searchPrefix = if ([string]::IsNullOrWhiteSpace($rootFolder)) { "" } else { "/$rootFolder/" }
    $targets = [System.Collections.Generic.List[string]]::new()
    foreach ($item in (Get-PnPListItem -List $pagesLibrary -PageSize 500)) {
        $fileRef = [string]$item.FieldValues.FileRef
        if ($fileRef -notlike "*.aspx") { continue }
        if ($searchPrefix -and $fileRef -notlike "*$searchPrefix*") { continue }
        $relative = $fileRef
        $marker = $searchPrefix.TrimEnd("/")
        $markerIndex = $relative.IndexOf($marker, [StringComparison]::OrdinalIgnoreCase)
        if ($markerIndex -ge 0) { $relative = $relative.Substring($markerIndex + 1) }
        $targets.Add($relative)
    }

    $total = $targets.Count
    Write-MarkstrataLog -Message "Applying settings to $total page(s)." -Component "PageSetting"

    $results = [System.Collections.Generic.List[object]]::new()
    $applied = 0; $unchanged = 0; $failed = 0; $index = 0
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    foreach ($target in $targets) {
        $index++
        $status = "Unchanged"
        try {
            $page = Get-PnPPage -Identity $target -ErrorAction Stop
            $control = $page.Sections[0].Controls[0]
            $existing = $control.PropertiesJson | ConvertFrom-Json

            $merged = [ordered]@{}
            foreach ($key in $rendering.Keys) { $merged[$key] = $rendering[$key] }
            # Per-page keys come from the page itself, so it keeps rendering its own document.
            foreach ($key in $perPageKeys) {
                if ($existing.PSObject.Properties.Name -contains $key) { $merged[$key] = $existing.$key }
            }

            $mergedJson = $merged | ConvertTo-Json -Depth 6 -Compress
            $currentJson = ($existing | ConvertTo-Json -Depth 6 -Compress)
            if ($mergedJson -eq $currentJson) {
                $unchanged++
            } elseif ($PSCmdlet.ShouldProcess($target, "Apply web part settings")) {
                Set-PnPPageWebPart -Page $target -Identity $control.InstanceId -PropertiesJson $mergedJson -ErrorAction Stop
                $applied++
                $status = "Applied"
            } else {
                $status = "WhatIf"
            }
        } catch {
            $failed++
            $status = "Failed"
            Write-MarkstrataLog -Message "Settings failed for '$target': $($_.Exception.Message)" -Level Error -Component "PageSetting" -NoConsole
        }

        $results.Add([pscustomobject]@{ Page = $target; Status = $status })
        Write-PageCreationProgress -PageIndex $index -TotalPages $total -ElapsedSeconds $stopwatch.Elapsed.TotalSeconds `
            -Status $status -Leaf ([System.IO.Path]::GetFileNameWithoutExtension($target)) -ErrorMessage ""
    }
    $stopwatch.Stop()
    Write-Progress -Activity "Applying page settings" -Completed

    if ($UpdateConfig -and $PSCmdlet.ShouldProcess("config/MarkstrataSiteBuilder.config.json", "Record web part settings")) {
        $configPath = Join-Path $script:ConfigRoot "MarkstrataSiteBuilder.config.json"
        $raw = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $stored = [ordered]@{}
        foreach ($key in $rendering.Keys) { $stored[$key] = $rendering[$key] }
        # contentSource and fileUrl are excluded from the per-page MERGE (each page keeps its own),
        # but they are mode settings rather than pointers at a document - identical on every page -
        # so config keeps recording them.
        $stored["contentSource"] = if ($templateProperties.PSObject.Properties.Name -contains "contentSource") { $templateProperties.contentSource } else { "library" }
        $stored["fileUrl"] = ""
        $raw.markdownPage.webPartProperties = [pscustomobject]$stored
        $raw | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $configPath -Encoding utf8NoBOM
        Write-MarkstrataLog -Message "Recorded $($rendering.Count) rendering property(ies) into config." -Component "PageSetting"
    }

    Write-MarkstrataLog -Message ("Page settings complete: {0} applied, {1} already matching, {2} failed in {3:mm\:ss}." -f $applied, $unchanged, $failed, $stopwatch.Elapsed) -Component "PageSetting"

    if ($PassThru) { return $results }

    return [pscustomobject]@{
        Source     = $FromPage
        Applied    = $applied
        Unchanged  = $unchanged
        Failed     = $failed
        Properties = $rendering.Count
        Elapsed    = $stopwatch.Elapsed
    }
}
