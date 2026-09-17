<#
    Helpers for the app-registration bootstrap. Kept apart from Register-MarkstrataApp so the
    command reads as the four steps it performs, and so the PnP-shape guesswork below has one home.
#>

function Resolve-MarkstrataTenantDomain {
    <#
    .SYNOPSIS
        Work out the tenant domain from the target site URL.

    .DESCRIPTION
        PnP's registration cmdlets want a domain ("contoso.onmicrosoft.com"), not the GUID that
        auth.tenantId usually holds, and asking for it again when it is already spelled out in the
        site URL is a question with an obvious answer. https://contoso.sharepoint.com/sites/docs
        gives "contoso.onmicrosoft.com".

        A tenant whose SharePoint host does not match its directory name - rare, but it happens
        after a rename or in a sovereign cloud - needs -Tenant passed explicitly.

    .PARAMETER SiteUrl
        The full site URL.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$SiteUrl)

    $config = Get-MarkstrataConfig
    $configured = [string](Get-OptionalProperty $config.Auth "tenantId" "")
    # A configured value is only useful here if it is a domain; a GUID is not accepted.
    if ($configured -and $configured.Contains(".")) { return $configured }

    $host_ = ([uri]$SiteUrl).Host
    $name = ($host_ -split "\.")[0]
    if ([string]::IsNullOrWhiteSpace($name)) {
        throw "Could not read a tenant name from '$SiteUrl'. Pass -Tenant explicitly."
    }
    return "$name.onmicrosoft.com"
}

function Get-MarkstrataAppRegistrationCommand {
    <#
    .SYNOPSIS
        The PnP cmdlet that creates an app-only registration WITH permission parameters.

    .DESCRIPTION
        PnP exposes this under two names, and which one is the real cmdlet has moved between
        versions: in 3.x Register-PnPEntraIDApp is an ALIAS for Register-PnPAzureADApp, and only
        the target carries -SharePointApplicationPermissions. Picking by capability rather than by
        name means the module works whichever way round a given release has it, and calling the
        resolved command rather than the alias keeps the intent visible in a transcript.

    .OUTPUTS
        System.Management.Automation.CommandInfo
    #>
    [CmdletBinding()]
    [OutputType([System.Management.Automation.CommandInfo])]
    param()

    foreach ($name in "Register-PnPAzureADApp", "Register-PnPEntraIDApp") {
        $command = Get-Command -Name $name -ErrorAction SilentlyContinue
        if (-not $command) { continue }
        # Resolve an alias to what it points at, so the capability test below sees the real
        # parameter list rather than the alias's.
        while ($command.CommandType -eq "Alias" -and $command.ResolvedCommand) { $command = $command.ResolvedCommand }
        if ($command.Parameters.ContainsKey("SharePointApplicationPermissions")) { return $command }
    }
    throw "No PnP cmdlet was found that can register an app with application permissions. Update PnP.PowerShell (3.0 or later) and retry."
}

function Get-MarkstrataCreatedAppId {
    <#
    .SYNOPSIS
        Read the client ID out of whatever shape the PnP registration cmdlet returned.

    .DESCRIPTION
        The result object's property is named "AzureAppId/ClientId" in some versions and "AppId"
        in others, and a slash in a property name is easy to get wrong. Trying the known spellings
        in order beats assuming one and silently saving an empty client ID.

    .PARAMETER Result
        The object returned by the registration cmdlet.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowNull()]$Result)

    if ($null -eq $Result) { return "" }
    foreach ($name in "AzureAppId/ClientId", "EntraIDAppId/ClientId", "AppId", "ClientId") {
        $value = [string](Get-OptionalProperty $Result $name "")
        if ($value) { return $value }
    }
    return ""
}

function Get-MarkstrataCreatedThumbprint {
    <#
    .SYNOPSIS
        Read the certificate thumbprint out of the PnP registration result.

    .PARAMETER Result
        The object returned by the registration cmdlet.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowNull()]$Result)

    if ($null -eq $Result) { return "" }
    foreach ($name in "Certificate Thumbprint", "CertificateThumbprint", "Thumbprint") {
        $value = [string](Get-OptionalProperty $Result $name "")
        if ($value) { return $value }
    }
    return ""
}
