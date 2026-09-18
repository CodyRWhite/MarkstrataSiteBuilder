function Get-MarkstrataConfig {
    <#
    .SYNOPSIS
        Resolve and cache the effective configuration.

    .DESCRIPTION
        Loads the shipped defaults from the module's own config\MarkstrataSiteBuilder.config.json
        and layers the per-user override from %LOCALAPPDATA%\MarkstrataSiteBuilder\config.json on
        top. The shipped file is only ever READ - it lives in the module folder, which an installed
        module cannot write to and which a module update replaces.
        Override values win section by section: within each top-level section any non-empty
        property in the override replaces the default. Documentation keys beginning '_' are
        ignored everywhere.

        Keeping the user's settings in a separate file is what lets the module be updated or
        reinstalled without overwriting them - nothing writes to the shipped config.

        markdown.libraryRoot supports the {UserProfile} token. The result is memoised for the
        session; -Force re-reads from disk.

    .PARAMETER Force
        Ignore the cached config and re-read from disk.
    #>
    [CmdletBinding()]
    param(
        [switch]$Force
    )

    if ($script:Config -and -not $Force) { return $script:Config }

    function Read-JsonFile {
        param([string]$Path)
        if (-not (Test-Path -LiteralPath $Path)) {
            throw "Required config file not found: $Path"
        }
        return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json)
    }

    # Strip documentation ('_'-prefixed) keys, converting an object to an ordered hashtable.
    function ConvertTo-SettingTable {
        param($Source)
        $table = [ordered]@{}
        if ($null -eq $Source) { return $table }
        $Source.PSObject.Properties |
            Where-Object { $_.Name -notlike "_*" } |
            ForEach-Object { $table[$_.Name] = $_.Value }
        return $table
    }

    $defaults = Read-JsonFile (Join-Path $script:TemplateRoot "MarkstrataSiteBuilder.config.json")

    # Build each top-level section as a hashtable so the user override can be layered in.
    $sections = [ordered]@{}
    foreach ($sectionProperty in ($defaults.PSObject.Properties | Where-Object { $_.Name -notlike "_*" })) {
        $sections[$sectionProperty.Name] = ConvertTo-SettingTable $sectionProperty.Value
    }

    if (Test-Path -LiteralPath $script:UserOverride) {
        $override = Get-Content -LiteralPath $script:UserOverride -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($overrideSection in ($override.PSObject.Properties | Where-Object { $_.Name -notlike "_*" })) {
            if (-not $sections.Contains($overrideSection.Name)) {
                $sections[$overrideSection.Name] = [ordered]@{}
            }
            $overrideSection.Value.PSObject.Properties |
                Where-Object { $_.Name -notlike "_*" -and $null -ne $_.Value -and "$($_.Value)" -ne "" } |
                ForEach-Object { $sections[$overrideSection.Name][$_.Name] = $_.Value }
        }
    }

    # Expand path templates.
    if ($sections["markdown"] -and $sections["markdown"]["libraryRoot"]) {
        $sections["markdown"]["libraryRoot"] = $sections["markdown"]["libraryRoot"].Replace("{UserProfile}", $env:USERPROFILE)
    }

    $resolved = [pscustomobject]@{
        SharePoint    = [pscustomobject]$sections["sharePoint"]
        Auth          = [pscustomobject]$sections["auth"]
        Run           = [pscustomobject]$sections["run"]
        Categories    = [pscustomobject]$sections["categories"]
        Navigation    = [pscustomobject]$sections["navigation"]
        Markdown      = [pscustomobject]$sections["markdown"]
        MarkdownPage  = [pscustomobject]$sections["markdownPage"]
        MarkdownIndex = [pscustomobject]$sections["markdownIndex"]
    }

    $script:Config = $resolved
    return $resolved
}
