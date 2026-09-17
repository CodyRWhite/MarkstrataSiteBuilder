function Register-MarkstrataApp {
    <#
    .SYNOPSIS
        Create the Entra ID app registration the builder signs in with, and save it as your
        configuration.

    .DESCRIPTION
        There are two kinds of app registration, for two different jobs, and this command creates
        either. Both are created through Entra's own consent prompts in the browser - nothing has
        to be clicked together by hand in the portal first.

        SIGN-IN APP (the default)
        A delegated app that lets you sign in as yourself. PnP PowerShell has shipped no shared
        sign-in app since version 2, so a tenant needs one of its own before Connect-PnPOnline
        will do anything interactively. This is what Connect-MarkstrataSite offers to create on a
        first run, because it is what makes any connection at all possible. It holds delegated
        permissions only: it can do what YOU can do, and nothing when you are not there.

        UNATTENDED APP (-Unattended)
        An app-only app with a certificate, for a scheduled refresh that runs with nobody signed
        in. It is granted Sites.Selected, which on its own grants nothing at all, and is then
        given access to THE TARGET SITE AND NOTHING ELSE. A leaked certificate therefore reaches
        one site. This is deliberately not Sites.FullControl.All, which would let a documentation
        publisher read and rewrite every site in the tenant.

        The certificate is created self-signed, installed in CurrentUser\My and exported to
        -CertificateOutPath. Only its thumbprint is written to config; the private key never is.

        Creating either app needs an account that may create app registrations and consent to
        permissions (Application Administrator or Global Administrator). The site grant for the
        unattended app additionally runs as you against the target site, so you must be an owner
        of that site - SharePoint Administrator alone returns 403 without site ownership.

    .PARAMETER Unattended
        Create the app-only app with a certificate and grant it access to the target site, rather
        than the delegated sign-in app. Requires an existing connection (run Connect-MarkstrataSite
        first) because the site grant is made as you.

    .PARAMETER Tenant
        Tenant domain, for example contoso.onmicrosoft.com. Read from the site URL when omitted.

    .PARAMETER ApplicationName
        Display name for the app registration. Defaults to auth.appDisplayName, with " Login"
        appended for the sign-in app so the two are told apart in Entra ID.

    .PARAMETER SitePermission
        Unattended only. Permission to grant on the target site: Read, Write, Manage or
        FullControl. Defaults to auth.sitePermission. Manage is the default because the builder
        creates folders and sets page metadata; Write is enough when the library already exists.

    .PARAMETER CertificateOutPath
        Unattended only. Folder to export the .cer and .pfx into. Defaults to the module's data
        folder under LOCALAPPDATA.

    .PARAMETER CertificatePassword
        Unattended only. Password for the exported .pfx, as a SecureString. A random one is used
        when omitted - the copy in CurrentUser\My is what the module actually reads.

    .PARAMETER ValidYears
        Unattended only. Certificate lifetime in years. Default 2.

    .PARAMETER DeviceLogin
        Sign in with a device code rather than a browser window.

    .PARAMETER SkipSiteGrant
        Unattended only. Create the app but do not grant it site access, for a tenant where app
        registration and site ownership belong to different people. Hand the reported client ID to
        a site owner to finish.

    .OUTPUTS
        PSCustomObject with Kind, ClientId, TenantId, Thumbprint, CertificatePath, SitePermission
        and ConfigPath.

    .EXAMPLE
        Register-MarkstrataApp

        Create the delegated sign-in app and save its client ID, so Connect-MarkstrataSite works.

    .EXAMPLE
        Register-MarkstrataApp -Unattended -SitePermission Write

        Add an app-only certificate app for scheduled runs, with the least privilege that works on
        a library whose folders already exist.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSAvoidUsingConvertToSecureStringWithPlainText", "",
        Justification = "Generates a throwaway password for the exported .pfx; the value is created here and never read from source or transmitted.")]
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = "High")]
    [OutputType([pscustomobject])]
    param(
        [switch]$Unattended,

        [string]$Tenant,

        [string]$ApplicationName,

        [ValidateSet("Read", "Write", "Manage", "FullControl")]
        [string]$SitePermission,

        [string]$CertificateOutPath,

        [System.Security.SecureString]$CertificatePassword,

        [ValidateRange(1, 10)]
        [int]$ValidYears = 2,

        [switch]$DeviceLogin,

        [switch]$SkipSiteGrant
    )

    $config = Get-MarkstrataConfig
    $siteUrl = [string]$config.SharePoint.siteUrl
    if ([string]::IsNullOrWhiteSpace($siteUrl)) {
        throw "No target site configured. Run Initialize-MarkstrataConfig first."
    }

    $baseName = [string](Get-OptionalProperty $config.Auth "appDisplayName" $script:AppName)
    if (-not $ApplicationName) {
        $ApplicationName = if ($Unattended) { $baseName } else { "$baseName Login" }
    }
    if (-not $Tenant) { $Tenant = Resolve-MarkstrataTenantDomain -SiteUrl $siteUrl }

    $action = if ($Unattended) { "Register '$ApplicationName' (app-only) and grant site access" } else { "Register '$ApplicationName' (delegated sign-in)" }
    if (-not $PSCmdlet.ShouldProcess("$Tenant / $siteUrl", $action)) {
        return [pscustomobject]@{
            Kind = $(if ($Unattended) { "Unattended" } else { "SignIn" })
            ClientId = ""; TenantId = $Tenant; Thumbprint = ""; CertificatePath = ""
            SitePermission = ""; ConfigPath = $script:UserOverride; Status = "WhatIf"
        }
    }

    if (-not $Unattended) {
        # ---- Delegated sign-in app -------------------------------------------------------------
        # Delegated permissions only: the app can do what the signed-in person can do. AllSites
        # .FullControl sounds broad but is bounded by the operator's own access, unlike the
        # application permission of the same name.
        Write-MarkstrataLog "Creating the sign-in app '$ApplicationName' in $Tenant. A browser will open for consent." -Level Info -Component "Register"
        $arguments = @{
            ApplicationName               = $ApplicationName
            Tenant                        = $Tenant
            SharePointDelegatePermissions = @("AllSites.FullControl")
            GraphDelegatePermissions      = @("Sites.FullControl.All")
            ErrorAction                   = "Stop"
        }
        if ($DeviceLogin) { $arguments["DeviceLogin"] = $true }
        $created = Register-PnPEntraIDAppForInteractiveLogin @arguments

        $clientId = Get-MarkstrataCreatedAppId -Result $created
        if ([string]::IsNullOrWhiteSpace($clientId)) {
            throw "The app was created but its client ID could not be read back. Find '$ApplicationName' in Entra ID and set it with Initialize-MarkstrataConfig -ClientId."
        }

        $configPath = Set-MarkstrataUserConfig -Section "auth" -Values @{
            clientId = $clientId; tenantId = $Tenant; appDisplayName = $baseName
        }
        Write-MarkstrataLog "Sign-in app ready ($clientId). Saved to $configPath." -Level Info -Component "Register"
        Write-MarkstrataLog "Consent can take a minute to propagate; if the first connection is refused, wait and retry." -Level Info -Component "Register"

        return [pscustomobject]@{
            Kind = "SignIn"; ClientId = $clientId; TenantId = $Tenant
            Thumbprint = ""; CertificatePath = ""; SitePermission = ""
            ConfigPath = $configPath
        }
    }

    # ---- App-only app with a certificate -------------------------------------------------------
    if (-not $SitePermission)     { $SitePermission     = [string](Get-OptionalProperty $config.Auth "sitePermission" "Manage") }
    if (-not $CertificateOutPath) { $CertificateOutPath = $script:DataRoot }
    if (-not (Test-Path -LiteralPath $CertificateOutPath)) {
        New-Item -ItemType Directory -Path $CertificateOutPath -Force | Out-Null
    }
    if (-not $CertificatePassword) {
        $CertificatePassword = ConvertTo-SecureString -String ([guid]::NewGuid().ToString("N")) -AsPlainText -Force
    }

    $registerCommand = Get-MarkstrataAppRegistrationCommand
    $arguments = @{
        ApplicationName                  = $ApplicationName
        Tenant                           = $Tenant
        OutPath                          = $CertificateOutPath
        CertificatePassword              = $CertificatePassword
        ValidYears                       = $ValidYears
        Store                            = "CurrentUser"
        SharePointApplicationPermissions = @("Sites.Selected")
        GraphApplicationPermissions      = @("Sites.Selected")
        ErrorAction                      = "Stop"
    }
    if ($DeviceLogin) { $arguments["DeviceLogin"] = $true }

    Write-MarkstrataLog "Creating the unattended app '$ApplicationName' in $Tenant. A browser will open for admin consent." -Level Info -Component "Register"
    $created = & $registerCommand @arguments

    $clientId   = Get-MarkstrataCreatedAppId -Result $created
    $thumbprint = Get-MarkstrataCreatedThumbprint -Result $created
    $pfxPath    = [string](Get-OptionalProperty $created "Pfx file" "")

    if ([string]::IsNullOrWhiteSpace($clientId)) {
        throw "The app was created but its client ID could not be read back. Find '$ApplicationName' in Entra ID and set it with Initialize-MarkstrataConfig -ClientId."
    }
    Write-MarkstrataLog "Created '$ApplicationName' ($clientId), certificate $thumbprint." -Level Info -Component "Register"

    # The grant is made as YOU, against the one site. It needs a signed-in connection, which the
    # brand-new app-only credential cannot provide - it has no access until this very grant exists.
    if (-not $SkipSiteGrant) {
        if (-not $script:SharePointReady) {
            Write-MarkstrataLog "Not connected, so the site grant cannot be made from here." -Level Warning -Component "Register"
            Write-MarkstrataLog "Run Connect-MarkstrataSite, then: Grant-PnPAzureADAppSitePermission -AppId $clientId -DisplayName '$ApplicationName' -Site $siteUrl -Permissions $SitePermission" -Level Warning -Component "Register"
        }
        else {
            Write-MarkstrataLog "Granting '$ApplicationName' $SitePermission on $siteUrl (and no other site)." -Level Info -Component "Register"
            try {
                $existingGrant = @(Get-PnPAzureADAppSitePermission -Site $siteUrl -ErrorAction SilentlyContinue) |
                    Where-Object { @($_.Apps.AppId) -contains $clientId } | Select-Object -First 1
                if ($existingGrant) {
                    # Re-running must not stack a second grant for the same app; raise the existing one.
                    Set-PnPAzureADAppSitePermission -Site $siteUrl -PermissionId $existingGrant.Id -Permissions $SitePermission -ErrorAction Stop | Out-Null
                    Write-MarkstrataLog "Existing grant updated to $SitePermission." -Level Info -Component "Register"
                }
                else {
                    Grant-PnPAzureADAppSitePermission -AppId $clientId -DisplayName $ApplicationName -Site $siteUrl -Permissions $SitePermission -ErrorAction Stop | Out-Null
                }
            }
            catch {
                # The app itself is worth keeping even when the grant fails, so report the fix
                # rather than throwing away a successful registration.
                Write-MarkstrataLog "Site grant failed: $($_.Exception.Message)" -Level Error -Component "Register"
                Write-MarkstrataLog "Add yourself to the site's Owners group and re-run, or ask a site owner for: Grant-PnPAzureADAppSitePermission -AppId $clientId -DisplayName '$ApplicationName' -Site $siteUrl -Permissions $SitePermission" -Level Warning -Component "Register"
            }
        }
    }

    $settings = @{ clientId = $clientId; tenantId = $Tenant; appDisplayName = $ApplicationName }
    if ($thumbprint) { $settings["certificateThumbprint"] = $thumbprint }
    $configPath = Set-MarkstrataUserConfig -Section "auth" -Values $settings

    Write-MarkstrataLog "Saved to $configPath. Reconnect with Connect-MarkstrataSite -Force to use it." -Level Info -Component "Register"

    return [pscustomobject]@{
        Kind            = "Unattended"
        ClientId        = $clientId
        TenantId        = $Tenant
        Thumbprint      = $thumbprint
        CertificatePath = $pfxPath
        SitePermission  = $(if ($SkipSiteGrant) { "not granted" } else { $SitePermission })
        ConfigPath      = $configPath
    }
}
