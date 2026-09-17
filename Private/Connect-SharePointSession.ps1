function Connect-SharePointSession {
    <#
    .SYNOPSIS
        Open the PnP connection to the target site and cache the web context.

    .DESCRIPTION
        One place where every connection is made, so the rest of the module never has to know
        which kind it got. Two modes:

          AppOnly      clientId + tenantId + a certificate (thumbprint from CurrentUser\My, or a
                       .pfx path and password). Unattended: this is what a scheduled refresh uses.
          Interactive  a browser (or device code) sign-in as the operator. Needs a client ID for
                       a delegated app registration - PnP has not shipped a shared one since v2,
                       so either the config carries one or PnP falls back to ENTRAID_CLIENT_ID.

        On success it caches the site's URL, server-relative URL and title in $script:SharePointSite
        and records the mode in $script:ConnectionMode. A failure here throws with PnP's own message
        intact; deciding whether that failure is worth offering to fix is the caller's job.

    .PARAMETER Interactive
        Force an interactive sign-in even when a certificate is configured.

    .PARAMETER DeviceLogin
        Sign in with a device code instead of a browser. For a host with no browser, or a remote
        session.

    .PARAMETER CertificateThumbprint
        Thumbprint of the app certificate in CurrentUser\My. Falls back to auth.certificateThumbprint.

    .PARAMETER CertificatePath
        Path to a .pfx holding the app certificate (use with -CertificatePassword).

    .PARAMETER CertificatePassword
        Password for the .pfx, as a SecureString.

    .OUTPUTS
        None. Sets module state.
    #>
    [CmdletBinding()]
    param(
        [switch]$Interactive,
        [switch]$DeviceLogin,
        [string]$CertificateThumbprint,
        [string]$CertificatePath,
        [System.Security.SecureString]$CertificatePassword
    )

    $config = Get-MarkstrataConfig
    $siteUrl = [string]$config.SharePoint.siteUrl
    if ([string]::IsNullOrWhiteSpace($siteUrl)) {
        throw "No target site configured. Run Initialize-MarkstrataConfig to set sharePoint.siteUrl."
    }

    $clientId  = [string](Get-OptionalProperty $config.Auth "clientId" "")
    $tenantId  = [string](Get-OptionalProperty $config.Auth "tenantId" "")
    $thumbprint = if ($CertificateThumbprint) {
        $CertificateThumbprint
    } else {
        [string](Get-OptionalProperty $config.Auth "certificateThumbprint" "")
    }

    $useAppOnly = (-not $Interactive) -and (-not $DeviceLogin) -and
                  $clientId -and ($CertificatePath -or $thumbprint)

    $connectArguments = @{ Url = $siteUrl; ErrorAction = "Stop" }

    if ($useAppOnly) {
        if ([string]::IsNullOrWhiteSpace($tenantId)) {
            throw "auth.clientId is set but auth.tenantId is not. Both are needed for an app-only connection."
        }
        $connectArguments["ClientId"] = $clientId
        $connectArguments["Tenant"]   = $tenantId
        if ($CertificatePath) {
            $connectArguments["CertificatePath"] = $CertificatePath
            if ($CertificatePassword) { $connectArguments["CertificatePassword"] = $CertificatePassword }
        }
        else {
            $connectArguments["Thumbprint"] = $thumbprint
        }
        $mode = "AppOnly"
    }
    else {
        if ($DeviceLogin) { $connectArguments["DeviceLogin"] = $true } else { $connectArguments["Interactive"] = $true }
        # A delegated sign-in still needs an app to sign in WITH. Pass the configured one when there
        # is one; otherwise let PnP use ENTRAID_CLIENT_ID, and let its own error explain if neither
        # exists - Connect-MarkstrataSite turns that into the offer to create one.
        if ($clientId) { $connectArguments["ClientId"] = $clientId }
        if ($tenantId) { $connectArguments["Tenant"]   = $tenantId }
        $mode = "Interactive"
    }

    Write-MarkstrataLog "Connecting to SharePoint ($mode): $siteUrl" -Level Info -Component "PnP"
    Connect-PnPOnline @connectArguments

    $web = Get-PnPWeb -ErrorAction Stop
    $script:SharePointSite = [pscustomobject]@{
        Url               = $web.Url
        ServerRelativeUrl = $web.ServerRelativeUrl
        Title             = $web.Title
    }
    $script:SharePointReady = $true
    $script:ConnectionMode  = $mode
    Write-MarkstrataLog "SharePoint connection OK: $($web.Title) ($($web.ServerRelativeUrl))." -Level Info -Component "PnP"
}
