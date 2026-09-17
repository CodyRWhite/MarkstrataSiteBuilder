function Initialize-MarkstrataConfig {
    <#
    .SYNOPSIS
        Set up, change or show the configuration for your site.

    .DESCRIPTION
        The first command to run. It writes your settings to
        %LOCALAPPDATA%\MarkstrataSiteBuilder\config.json, which is layered over the module's
        shipped defaults - so the module can be updated or reinstalled without taking your
        configuration with it, and nothing of yours lives in the module folder.

        Called with no parameters in an interactive session it asks for what it needs, showing the
        current value as the default so re-running it is a way to review rather than retype.
        Called with parameters it just sets those, which is what a scripted setup wants.

        Only three things genuinely have to be decided:

          SiteUrl          the SharePoint site the documentation will live on
          LibraryRoot      the local folder holding the .md files, normally a synced copy of the
                           library, since the authoring model is edit-the-file-and-save
          HomeTitle        what the home index is called

        Everything else is derived or has a working default. The library's server-relative URL is
        read from the site URL unless you pass one, which covers every site whose documents live in
        the default library.

        This command writes no credential. Sign-in is set up separately by Register-MarkstrataApp,
        or offered automatically the first time you connect.

    .PARAMETER SiteUrl
        Full URL of the target SharePoint site, for example https://contoso.sharepoint.com/sites/docs.

    .PARAMETER LibraryRoot
        Local path to the Markdown library. Supports the {UserProfile} token so a config can be
        shared between machines with different user names.

    .PARAMETER LibraryServerRelativeUrl
        Server-relative path of the same library in SharePoint, for example
        /sites/docs/Shared Documents. Derived from -SiteUrl when omitted.

    .PARAMETER DocumentLibrary
        The library's list TITLE, which is what Get-PnPListItem takes. "Documents" for the default
        library, even though its path says "Shared Documents".

    .PARAMETER HomeTitle
        Heading of the generated home index, and the title of the renderer page.

    .PARAMETER HomeIntro
        A sentence under that heading. Pass "" for none.

    .PARAMETER ClientId
        Client ID of an app registration you already have, if you are not using
        Register-MarkstrataApp.

    .PARAMETER TenantId
        Tenant ID or domain for that app registration.

    .PARAMETER CertificateThumbprint
        Thumbprint of that app's certificate in CurrentUser\My, for unattended runs.

    .PARAMETER Show
        Print the effective configuration and the file it came from, changing nothing.

    .OUTPUTS
        PSCustomObject describing the effective settings and the path they were written to.

    .EXAMPLE
        Initialize-MarkstrataConfig

        Ask for the settings, showing the current values as defaults.

    .EXAMPLE
        Initialize-MarkstrataConfig -SiteUrl https://contoso.sharepoint.com/sites/docs `
            -LibraryRoot "{UserProfile}\Contoso\Docs - Documents" -HomeTitle "Documentation"

        Scripted setup, no prompts.

    .EXAMPLE
        Initialize-MarkstrataConfig -Show

        Review what is configured and where it is stored.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [string]$SiteUrl,
        [string]$LibraryRoot,
        [string]$LibraryServerRelativeUrl,
        [string]$DocumentLibrary,
        [string]$HomeTitle,
        [string]$HomeIntro,
        [string]$ClientId,
        [string]$TenantId,
        [string]$CertificateThumbprint,
        [switch]$Show
    )

    $config = Get-MarkstrataConfig -Force

    if ($Show) {
        return [pscustomobject]@{
            ConfigPath               = $script:UserOverride
            ConfigExists             = (Test-Path -LiteralPath $script:UserOverride)
            SiteUrl                  = [string]$config.SharePoint.siteUrl
            LibraryRoot              = [string]$config.Markdown.libraryRoot
            LibraryServerRelativeUrl = [string]$config.Markdown.libraryServerRelativeUrl
            DocumentLibrary          = [string]$config.Markdown.documentLibrary
            HomeTitle                = [string]$config.MarkdownIndex.homeTitle
            ClientId                 = [string](Get-OptionalProperty $config.Auth "clientId" "")
            TenantId                 = [string](Get-OptionalProperty $config.Auth "tenantId" "")
            CertificateThumbprint    = [string](Get-OptionalProperty $config.Auth "certificateThumbprint" "")
            SignInMode               = $(if ((Get-OptionalProperty $config.Auth "certificateThumbprint" "")) { "App-only (unattended)" }
                                         elseif ((Get-OptionalProperty $config.Auth "clientId" "")) { "Interactive" }
                                         else { "Not configured" })
        }
    }

    # An interactive run asks only for what was not supplied, and offers the current value as the
    # default, so re-running to change one setting does not mean retyping the rest.
    $askedFor = $PSBoundParameters.Keys
    $interactive = $askedFor.Count -eq 0
    if ($interactive) {
        $SiteUrl     = Read-MarkstrataSetting "SharePoint site URL" ([string]$config.SharePoint.siteUrl)
        $LibraryRoot = Read-MarkstrataSetting "Local path to the Markdown library" ([string]$config.Markdown.libraryRoot)
        $HomeTitle   = Read-MarkstrataSetting "Title for the home index" ([string]$config.MarkdownIndex.homeTitle)
        $HomeIntro   = Read-MarkstrataSetting "One-line intro under that title (blank for none)" ([string]$config.MarkdownIndex.homeIntro)
    }

    if ($SiteUrl) {
        if ($SiteUrl -notmatch '^https?://') { throw "SiteUrl must be a full URL, for example https://contoso.sharepoint.com/sites/docs." }
        $SiteUrl = $SiteUrl.TrimEnd("/")
    }
    if ($LibraryRoot) {
        # Kept unexpanded on the way in: the {UserProfile} token is the point, so a config file can
        # be copied to another machine or another account and still resolve.
        $probe = $LibraryRoot.Replace("{UserProfile}", $env:USERPROFILE)
        if (-not (Test-Path -LiteralPath $probe)) {
            Write-MarkstrataLog "Library root '$probe' does not exist yet. Create it, or point at the synced library, before publishing." -Level Warning -Component "Config"
        }
    }
    if (-not $LibraryServerRelativeUrl -and $SiteUrl) {
        # The default documents library of any modern site. Passed explicitly for anything else.
        $LibraryServerRelativeUrl = "{0}/Shared Documents" -f ([uri]$SiteUrl).AbsolutePath.TrimEnd("/")
    }

    if (-not $PSCmdlet.ShouldProcess($script:UserOverride, "Save configuration")) {
        return [pscustomobject]@{ ConfigPath = $script:UserOverride; Updated = @(); Status = "WhatIf" }
    }

    $written = [System.Collections.Generic.List[string]]::new()

    $sharePointValues = @{}
    if ($SiteUrl) { $sharePointValues["siteUrl"] = $SiteUrl; $written.Add("sharePoint.siteUrl") }
    if ($sharePointValues.Count -gt 0) { Set-MarkstrataUserConfig -Section "sharePoint" -Values $sharePointValues | Out-Null }

    $markdownValues = @{}
    if ($LibraryRoot)              { $markdownValues["libraryRoot"] = $LibraryRoot; $written.Add("markdown.libraryRoot") }
    if ($LibraryServerRelativeUrl) { $markdownValues["libraryServerRelativeUrl"] = $LibraryServerRelativeUrl; $written.Add("markdown.libraryServerRelativeUrl") }
    if ($DocumentLibrary)          { $markdownValues["documentLibrary"] = $DocumentLibrary; $written.Add("markdown.documentLibrary") }
    if ($markdownValues.Count -gt 0) { Set-MarkstrataUserConfig -Section "markdown" -Values $markdownValues | Out-Null }

    # HomeIntro is deliberately checked against the bound parameters, not for truthiness: "" is a
    # real choice (no intro line) and must not be mistaken for "not supplied".
    $indexValues = @{}
    if ($HomeTitle) { $indexValues["homeTitle"] = $HomeTitle; $written.Add("markdownIndex.homeTitle") }
    if ($interactive -or $askedFor -contains "HomeIntro") { $indexValues["homeIntro"] = $HomeIntro; $written.Add("markdownIndex.homeIntro") }
    if ($indexValues.Count -gt 0) { Set-MarkstrataUserConfig -Section "markdownIndex" -Values $indexValues | Out-Null }

    $authValues = @{}
    if ($ClientId)              { $authValues["clientId"] = $ClientId; $written.Add("auth.clientId") }
    if ($TenantId)              { $authValues["tenantId"] = $TenantId; $written.Add("auth.tenantId") }
    if ($CertificateThumbprint) { $authValues["certificateThumbprint"] = $CertificateThumbprint; $written.Add("auth.certificateThumbprint") }
    if ($authValues.Count -gt 0) { Set-MarkstrataUserConfig -Section "auth" -Values $authValues | Out-Null }

    if ($written.Count -eq 0) {
        Write-MarkstrataLog "Nothing to change. Use -Show to review the current configuration." -Level Warning -Component "Config"
    }
    else {
        Write-MarkstrataLog "Saved $($written.Count) setting(s) to $script:UserOverride." -Level Info -Component "Config"
    }

    $config = Get-MarkstrataConfig -Force
    return [pscustomobject]@{
        ConfigPath               = $script:UserOverride
        SiteUrl                  = [string]$config.SharePoint.siteUrl
        LibraryRoot              = [string]$config.Markdown.libraryRoot
        LibraryServerRelativeUrl = [string]$config.Markdown.libraryServerRelativeUrl
        DocumentLibrary          = [string]$config.Markdown.documentLibrary
        HomeTitle                = [string]$config.MarkdownIndex.homeTitle
        Updated                  = $written.ToArray()
        NextStep                 = $(if ((Get-OptionalProperty $config.Auth "clientId" "")) { "Connect-MarkstrataSite" } else { "Connect-MarkstrataSite (it will offer to create an app registration)" })
    }
}
