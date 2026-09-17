function Remove-StaleFooterNode {
    <#
    .SYNOPSIS
        Remove footer links that point at pages outside the Markdown page root.

    .DESCRIPTION
        A communication site ships with footer links to its sample pages - "Our leadership",
        "Our teams", "Vision and priorities", "Culture" - which live under SitePages/Templates.
        Those pages are part of the legacy set, so once they are removed the footer is left
        advertising four dead links.

        Only stale INTERNAL links are pruned. An external link (http/https) or anything already
        under the Markdown page root is deliberate and left alone, so this can be re-run safely
        and will not quietly delete a footer someone has curated.

    .OUTPUTS
        System.Int32 - the number of nodes removed.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param()

    $config = Get-MarkstrataConfig
    $keepPrefix = "$(Get-MarkstrataSiteRelativeRoot)/$($config.SharePoint.pagesLibrary.Replace(' ', ''))"
    $rootFolder = Get-MarkdownPageFolderPath -Folder ""
    if (-not [string]::IsNullOrWhiteSpace($rootFolder)) { $keepPrefix += "/$rootFolder" }

    $removed = 0
    foreach ($footerNode in @(Get-PnPNavigationNode -Location Footer -ErrorAction SilentlyContinue)) {
        $nodeUrl = [string]$footerNode.Url
        if ([string]::IsNullOrWhiteSpace($nodeUrl)) { continue }
        if ($nodeUrl -match '^https?://') { continue }
        if ($nodeUrl.StartsWith($keepPrefix, [StringComparison]::OrdinalIgnoreCase)) { continue }

        Remove-PnPNavigationNode -Identity $footerNode.Id -Force -ErrorAction SilentlyContinue
        $removed++
        Write-MarkstrataLog -Message "Footer link removed (outside the Markdown pages): '$($footerNode.Title)' -> $nodeUrl" -Component "Navigation" -NoConsole
    }

    if ($removed -gt 0) {
        Write-MarkstrataLog -Message "Footer: $removed stale link(s) removed." -Component "Navigation"
    }
    return $removed
}
