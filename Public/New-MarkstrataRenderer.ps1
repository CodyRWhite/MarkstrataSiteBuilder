function New-MarkstrataRenderer {
    <#
    .SYNOPSIS
        Create the single page that renders the whole library through a strataDoc query string.

    .DESCRIPTION
        The Markdown web part accepts a strataDoc query parameter naming the document to show, so
        ONE page serves every document:

            /sites/docs/SitePages/Wiki.aspx?strataDoc=%2Fsites%2Fdocs%2FShared%20Documents%2FAlpha%2FPage%20One.md

        That is what removes the need for a page per document. A library of any size needs one
        page rather than one per document plus one per index, and the deployment drops from minutes
        to seconds - because adding a document no longer means creating anything in SharePoint.

        The page's own selectedFile is the home index, so visiting it with no query string shows
        the home page. It carries the same rendering settings as every other page, taken from
        markdownPage.webPartProperties.

        It lives at the ROOT of the pages library, not under the page root folder, so its URL stays
        short and does not move if the page root is renamed.

    .PARAMETER DefaultDocument
        Document shown when no strataDoc is supplied. Defaults to the home index
        (markdownIndex.homeFileName).

    .PARAMETER SetHomePage
        Also make this the site's welcome page. Worth doing once the per-document pages are
        retired, since the old home page will no longer exist.

    .PARAMETER Force
        Recreate the page if it already exists.

    .OUTPUTS
        PSCustomObject with Url, DefaultDocument, ExampleLink and Status.

    .EXAMPLE
        New-MarkstrataRenderer -SetHomePage

        Create the renderer and land the site on it.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [string]$DefaultDocument,

        [switch]$SetHomePage,

        [switch]$Force
    )

    if (-not $script:SharePointReady) {
        throw "Not connected. Run Connect-MarkstrataSite first."
    }

    $config = Get-MarkstrataConfig
    $rendererLeaf = [string](Get-OptionalProperty $config.MarkdownPage "rendererPage" "Wiki.aspx")
    if ([string]::IsNullOrWhiteSpace($DefaultDocument)) {
        $DefaultDocument = [string]$config.MarkdownIndex.homeFileName
    }

    $pagesSegment = ([string]$config.SharePoint.pagesLibrary).Replace(" ", "")
    $rendererUrl = "{0}/{1}/{2}" -f (Get-MarkstrataSiteRelativeRoot), $pagesSegment, $rendererLeaf
    $documentUrl = Get-MarkdownFileServerRelativeUrl -Folder "" -FileName $DefaultDocument

    $existing = $null
    try { $existing = Get-PnPPage -Identity $rendererLeaf -ErrorAction Stop } catch { $existing = $null }
    if ($existing -and -not $Force) {
        return [pscustomobject]@{
            Url = $rendererUrl; DefaultDocument = $documentUrl
            ExampleLink = (Get-MarkdownRendererUrl -Folder "" -FileName $DefaultDocument)
            Status = "Skipped"
        }
    }

    if (-not $PSCmdlet.ShouldProcess($rendererUrl, "Create the Markdown renderer page")) {
        return [pscustomobject]@{ Url = $rendererUrl; DefaultDocument = $documentUrl; ExampleLink = ""; Status = "WhatIf" }
    }

    $properties = [ordered]@{}
    foreach ($property in $config.MarkdownPage.webPartProperties.PSObject.Properties) {
        if ($property.Name -like "_*") { continue }
        $properties[$property.Name] = $property.Value
    }
    $properties["contentSource"]   = "library"
    $properties["selectedLibrary"] = [string]$config.Markdown.libraryServerRelativeUrl.TrimEnd("/")
    $properties["selectedFolder"]  = ""
    $properties["selectedFile"]    = $documentUrl
    $properties["fileMetadata"]    = [ordered]@{
        name              = $DefaultDocument
        serverRelativeUrl = $documentUrl
        timeLastModified  = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
        author            = ""
        length            = "0"
    }

    $layoutType = [string]$config.MarkdownPage.layoutType
    if ([string]::IsNullOrWhiteSpace($layoutType)) { $layoutType = "SingleWebPartAppPage" }

    $null = Add-PnPPage -Name $rendererLeaf -LayoutType $layoutType -ErrorAction Stop

    # A component OBJECT, not a name or a GUID: -Component attaches an empty control rather than
    # failing when it matches nothing, which would leave the one page the whole site depends on
    # rendering blank. Assert-MarkstrataWebPart is what turns that into an error.
    $component = Resolve-MarkstrataComponent -Page $rendererLeaf
    $null = Add-PnPPageWebPart -Page $rendererLeaf -Component $component `
        -WebPartProperties ($properties | ConvertTo-Json -Depth 6 -Compress) -ErrorAction Stop
    Assert-MarkstrataWebPart -Page $rendererLeaf -ComponentId ([string](Get-OptionalProperty $component "Id" ""))

    $setArguments = @{ Identity = $rendererLeaf; Title = [string]$config.MarkdownIndex.homeTitle; ErrorAction = "Stop" }
    if ([bool]$config.MarkdownPage.publish) { $setArguments["Publish"] = $true }
    Set-PnPPage @setArguments | Out-Null

    Write-MarkstrataLog -Message "Renderer page ready: $rendererUrl (default document $documentUrl)" -Component "Renderer"

    $homePageSet = $null
    if ($SetHomePage) {
        try {
            Set-PnPHomePage -RootFolderRelativeUrl "$pagesSegment/$rendererLeaf" -ErrorAction Stop
            $homePageSet = "$pagesSegment/$rendererLeaf"
            Write-MarkstrataLog -Message "Site home page set to $homePageSet." -Component "Renderer"
        } catch {
            Write-MarkstrataLog -Message "Could not set the home page: $($_.Exception.Message)" -Level Warning -Component "Renderer"
        }
    }

    return [pscustomobject]@{
        Url             = $rendererUrl
        DefaultDocument = $documentUrl
        # A shape-of-the-URL sample for the caller to look at. The folder is a placeholder, not
        # a category that has to exist.
        ExampleLink     = (Get-MarkdownRendererUrl -Folder "Example Category" -FileName "Index.md")
        HomePage        = $homePageSet
        Status          = $(if ($existing) { "Updated" } else { "Created" })
    }
}
