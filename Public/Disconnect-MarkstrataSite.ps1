function Disconnect-MarkstrataSite {
    <#
    .SYNOPSIS
        Close the SharePoint connection and clear the cached session state.

    .DESCRIPTION
        Safe to call when not connected. The cached web context and category data are cleared as
        well, so a later Connect-MarkstrataSite against a different site cannot pick up the
        previous one's category list or server-relative URL.

    .OUTPUTS
        None.

    .EXAMPLE
        Disconnect-MarkstrataSite
    #>
    [CmdletBinding()]
    param()

    if ($script:SharePointReady) {
        try {
            Disconnect-PnPOnline -ErrorAction Stop
            Write-MarkstrataLog "SharePoint connection closed." -Level Info -Component "PnP"
        }
        catch {
            Write-MarkstrataLog "PnP disconnect failed (ignored): $($_.Exception.Message)" -Level Warning -Component "PnP" -NoConsole
        }
    }

    $script:SharePointReady   = $false
    $script:SharePointSite    = $null
    $script:ConnectionMode    = $null
    $script:CategoryData      = $null
    $script:CategoryGroupData = $null
}
