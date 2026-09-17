function Connect-MarkstrataSite {
    <#
    .SYNOPSIS
        Connect to the target SharePoint site, offering to create the app registration if there
        is not one yet.

    .DESCRIPTION
        The first command of any session. It picks the strongest connection the configuration
        supports and falls back gracefully:

          1. An app registration and certificate in config -> app-only. Unattended, and what a
             scheduled refresh uses.
          2. Otherwise an interactive sign-in as you.
          3. If the interactive sign-in cannot start because there is no app registration to sign
             in with, you are told so and offered one: answering yes runs Register-MarkstrataApp,
             which creates the app, grants it access to THIS SITE ONLY, writes the client ID and
             certificate thumbprint to your user config, and reconnects app-only.

        Step 3 is why nothing here has to be set up by hand in the portal first. It needs an
        account that may create app registrations and consent to permissions; if yours may not,
        pass -NoBootstrap and hand Register-MarkstrataApp to someone who can.

        No secret is ever written to config: the certificate lives in the Windows certificate
        store and only its thumbprint is recorded.

    .PARAMETER Interactive
        Sign in as yourself even when a certificate is configured. Useful to check what your own
        account can see, or to run a one-off from a machine without the certificate.

    .PARAMETER DeviceLogin
        Use a device code rather than a browser window. For a host with no browser.

    .PARAMETER CertificateThumbprint
        Thumbprint of the app certificate in CurrentUser\My, overriding auth.certificateThumbprint.

    .PARAMETER CertificatePath
        Path to a .pfx holding the app certificate (use with -CertificatePassword). For a machine
        where the certificate is not installed in the store, such as a build agent.

    .PARAMETER CertificatePassword
        Password for the .pfx given by -CertificatePath, as a SecureString.

    .PARAMETER NoBootstrap
        Never offer to create an app registration. A failed connection just fails, which is what
        you want in automation and in any session that must not prompt.

    .PARAMETER Force
        Reconnect even if this session is already connected.

    .OUTPUTS
        PSCustomObject describing the connection (Site, Url, Mode), or nothing when already
        connected.

    .EXAMPLE
        Connect-MarkstrataSite

        Connect however the configuration allows, offering to bootstrap an app registration on a
        first run.

    .EXAMPLE
        Connect-MarkstrataSite -Interactive

        Sign in as yourself, ignoring the configured certificate.

    .EXAMPLE
        Connect-MarkstrataSite -CertificatePath .\builder.pfx -CertificatePassword (Read-Host -AsSecureString)

        App-only from a machine that does not have the certificate installed.
    #>
    [CmdletBinding(DefaultParameterSetName = "Thumbprint")]
    [OutputType([pscustomobject])]
    param(
        [switch]$Interactive,

        [switch]$DeviceLogin,

        [Parameter(ParameterSetName = "Thumbprint")]
        [string]$CertificateThumbprint,

        [Parameter(ParameterSetName = "Pfx", Mandatory)]
        [string]$CertificatePath,

        [Parameter(ParameterSetName = "Pfx")]
        [System.Security.SecureString]$CertificatePassword,

        [switch]$NoBootstrap,

        [switch]$Force
    )

    $config = Get-MarkstrataConfig -Force

    if ([string]::IsNullOrWhiteSpace([string]$config.SharePoint.siteUrl)) {
        throw "No target site configured. Run Initialize-MarkstrataConfig first."
    }

    if ($script:SharePointReady -and -not $Force) {
        Write-MarkstrataLog "Already connected to $($script:SharePointSite.Url) ($script:ConnectionMode). Use -Force to reconnect." -Level Info
        return
    }

    $sessionArguments = @{}
    if ($Interactive)           { $sessionArguments["Interactive"]           = $true }
    if ($DeviceLogin)           { $sessionArguments["DeviceLogin"]           = $true }
    if ($CertificateThumbprint) { $sessionArguments["CertificateThumbprint"] = $CertificateThumbprint }
    if ($CertificatePath)       { $sessionArguments["CertificatePath"]       = $CertificatePath }
    if ($CertificatePassword)   { $sessionArguments["CertificatePassword"]   = $CertificatePassword }

    try {
        Connect-SharePointSession @sessionArguments
    }
    catch {
        $failure = $_
        # PnP has shipped no shared sign-in app since v2, so an interactive connect with no client
        # ID anywhere fails before it reaches the network. That specific failure is the one worth
        # offering to fix; anything else (wrong site, no access, expired certificate) is a real
        # error and is rethrown untouched.
        $needsApp = -not (Get-OptionalProperty $config.Auth "clientId" "") -and
                    [string]::IsNullOrWhiteSpace($env:ENTRAID_CLIENT_ID)

        if ($NoBootstrap -or -not $needsApp) { throw }

        Write-MarkstrataLog "No app registration is configured, so there is nothing to sign in with." -Level Warning -Component "PnP"
        Write-MarkstrataLog "PnP reported: $($failure.Exception.Message)" -Level Info -Component "PnP" -NoConsole

        $bootstrap = $false
        try {
            $bootstrap = $PSCmdlet.ShouldContinue(
                ("Create an Entra ID app registration named '{0}', grant it access to {1} only, and save it as your configuration?" -f
                    (Get-OptionalProperty $config.Auth "appDisplayName" $script:AppName), $config.SharePoint.siteUrl),
                "No app registration found")
        }
        catch {
            # A non-interactive host cannot answer, and a prompt there is fatal rather than merely
            # unanswered - so say what to run instead of dying on the prompt.
            throw "No app registration is configured and this session cannot prompt. Run Register-MarkstrataApp once, interactively, then retry. Original error: $($failure.Exception.Message)"
        }

        if (-not $bootstrap) {
            throw "Cancelled. Run Register-MarkstrataApp when you are ready, or set auth.clientId yourself with Initialize-MarkstrataConfig."
        }

        Register-MarkstrataApp | Out-Null
        Get-MarkstrataConfig -Force | Out-Null
        Connect-SharePointSession
    }

    return [pscustomobject]@{
        Site = $script:SharePointSite.Title
        Url  = $script:SharePointSite.Url
        Mode = $script:ConnectionMode
    }
}
