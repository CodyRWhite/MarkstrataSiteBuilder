function New-MarkstrataPage {
    <#
    .SYNOPSIS
        Create (or refresh) one modern page that renders a Markdown file from the document library.

    .DESCRIPTION
        The page is a SingleWebPartAppPage holding a single Markstrata web part whose
        contentSource is "library" and whose selectedFile is the .md file's server-relative URL. The page therefore holds NO copy
        of the content: editing the Markdown file - locally through the synced folder, or in the
        browser - updates the page, which is the whole point of this layout.

        Which web part is markdownPage.componentId's decision - the package installs more than one -
        and the page is verified to carry it before the build is called a success.

        SingleWebPartAppPage also gives the canvas its full width and no page banner, so the
        rendered document is the whole page rather than a column inside one.

    .PARAMETER FileName
        The Markdown file's name, including the .md extension.

    .PARAMETER Folder
        The category folder holding the file inside the library (empty for the library root). The
        page is created at SitePages/<markdownPage.pageRootFolder>/<Folder>/.

    .PARAMETER Title
        Page title. Defaults to the file name without its extension.

    .PARAMETER Category
        Optional value stamped into the sharePoint.categoryColumn column, when one is configured.

    .PARAMETER Length
        Optional file size in bytes, recorded in the web part's cached fileMetadata.

    .PARAMETER ComponentId
        Build this page with a specific web part instead of the configured one. The package installs
        more than one component, and this is what lets a run target the other without editing config.

    .PARAMETER Force
        Recreate the page even when it already exists. Without it an existing page is left alone.

    .OUTPUTS
        PSCustomObject with Title, PageName, Url, MarkdownUrl and Status
        (Created | Updated | Skipped | Failed).

    .EXAMPLE
        New-MarkstrataPage -FileName "Page One.md" -Folder "Alpha"

        Publish a page rendering Alpha\Page One.md from the library.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$FileName,

        [AllowEmptyString()]
        [string]$Folder = "",

        [string]$Title,

        [AllowEmptyString()]
        [string]$Category = "",

        [long]$Length = 0,

        [string]$ComponentId = "",

        [switch]$Force
    )

    begin {
        if (-not $script:SharePointReady) {
            throw "Not connected. Run Connect-MarkstrataSite first."
        }
        $config = Get-MarkstrataConfig
    }

    process {
        $leafName = [System.IO.Path]::GetFileNameWithoutExtension($FileName)
        if ([string]::IsNullOrWhiteSpace($Title)) { $Title = $leafName }

        $pageFolder   = Get-MarkdownPageFolderPath -Folder $Folder
        $pageName     = if ([string]::IsNullOrWhiteSpace($pageFolder)) { "$leafName.aspx" } else { "$pageFolder/$leafName.aspx" }
        $pageUrl      = Get-MarkdownPageServerRelativeUrl -Folder $Folder -LeafName $leafName
        $markdownUrl  = Get-MarkdownFileServerRelativeUrl -Folder $Folder -FileName $FileName

        $result = [pscustomobject]@{
            Title       = $Title
            PageName    = $pageName
            Url         = $pageUrl
            MarkdownUrl = $markdownUrl
            Status      = "Skipped"
            Message     = ""
        }

        $overwrite = $Force -or [bool]$config.MarkdownPage.overwriteExisting

        $existingPage = $null
        try { $existingPage = Get-PnPPage -Identity $pageName -ErrorAction Stop } catch { $existingPage = $null }
        if ($existingPage -and -not $overwrite) {
            $result.Message = "Page already exists."
            return $result
        }

        if (-not $PSCmdlet.ShouldProcess($pageUrl, "Create Markdown page")) {
            $result.Status = "WhatIf"
            return $result
        }

        try {
            # Properties are the configured rendering options plus this file's location. The
            # web part caches fileMetadata at configuration time; it is a snapshot for display,
            # while selectedFile is what actually gets fetched, so a stale length is harmless.
            $properties = [ordered]@{}
            foreach ($property in $config.MarkdownPage.webPartProperties.PSObject.Properties) {
                if ($property.Name -like "_*") { continue }
                $properties[$property.Name] = $property.Value
            }
            $properties["contentSource"]  = "library"
            $properties["selectedLibrary"] = [string]$config.Markdown.libraryServerRelativeUrl.TrimEnd("/")
            $properties["selectedFolder"]  = $Folder
            $properties["selectedFile"]    = $markdownUrl
            $properties["fileMetadata"]    = [ordered]@{
                name              = $FileName
                serverRelativeUrl = $markdownUrl
                timeLastModified  = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
                author            = ""
                length            = "$Length"
            }
            $propertiesJson = $properties | ConvertTo-Json -Depth 6 -Compress

            # Add-PnPPage resets the canvas of an existing page in a folder, which is exactly the
            # refresh behaviour wanted here; a root page would throw instead, but these pages all
            # live under the configured page root folder.
            $layoutType = [string]$config.MarkdownPage.layoutType
            if ([string]::IsNullOrWhiteSpace($layoutType)) { $layoutType = "SingleWebPartAppPage" }
            $null = Add-PnPPage -Name $pageName -LayoutType $layoutType -ErrorAction Stop

            # Resolved to a component OBJECT, never a name or a GUID string: -Component silently
            # attaches an empty control when it matches nothing, and the page then renders blank
            # while this command reports success. The assert afterwards is what makes that an error.
            $component = Resolve-MarkstrataComponent -Page $pageName -ComponentId $ComponentId
            $null = Add-PnPPageWebPart -Page $pageName -Component $component -WebPartProperties $propertiesJson -ErrorAction Stop
            Assert-MarkstrataWebPart -Page $pageName -ComponentId ([string](Get-OptionalProperty $component "Id" ""))

            $setPageArguments = @{ Identity = $pageName; Title = $Title; ErrorAction = "Stop" }
            if ([bool]$config.MarkdownPage.publish) { $setPageArguments["Publish"] = $true }
            Set-PnPPage @setPageArguments | Out-Null

            # Stamp the source metadata when the columns exist; absent columns are not fatal.
            $fieldValues = @{}
            # Optional: stamps the category onto the page so search and library views can group
            # by it. Skipped entirely when the column is not configured, because setting a field
            # that does not exist fails the whole page update.
            $categoryColumn = [string](Get-OptionalProperty $config.SharePoint "categoryColumn" "")
            if ($Category -and $categoryColumn) {
                $fieldValues[$categoryColumn] = $Category
            }
            if ($fieldValues.Count -gt 0) {
                try {
                    $pageItem = Get-PnPPage -Identity $pageName -ErrorAction Stop
                    Set-PnPListItem -List $config.SharePoint.pagesLibrary -Identity $pageItem.PageId -Values $fieldValues -UpdateType SystemUpdate -ErrorAction Stop | Out-Null
                } catch {
                    Write-MarkstrataLog -Message "Metadata not stamped on '$Title': $($_.Exception.Message)" -Level Warning -Component "MarkdownPage" -NoConsole
                }
            }

            $result.Status = if ($existingPage) { "Updated" } else { "Created" }
            Write-MarkstrataLog -Message "$($result.Status): $pageUrl -> $markdownUrl" -Component "MarkdownPage" -NoConsole
        } catch {
            $result.Status = "Failed"
            $result.Message = $_.Exception.Message
            Write-MarkstrataLog -Message "Page failed for '$Title': $($_.Exception.Message)" -Level Error -Component "MarkdownPage" -NoConsole
        }

        return $result
    }
}
