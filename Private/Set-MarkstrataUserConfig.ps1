function Set-MarkstrataUserConfig {
    <#
    .SYNOPSIS
        Write settings into the per-user config override, merging with what is already there.

    .DESCRIPTION
        The shipped config/MarkstrataSiteBuilder.config.json is never written to: updating or
        reinstalling the module would take your settings with it. Everything a user changes lands
        in %LOCALAPPDATA%\MarkstrataSiteBuilder\config.json instead, and the loader layers it over
        the defaults.

        The merge is per property, not per section: writing auth.clientId leaves auth.tenantId and
        every other section exactly as they were. A value of $null or an empty string REMOVES the
        property, which is how a setting is returned to its shipped default.

        The file is written UTF-8 without a BOM - a BOM makes ConvertFrom-Json choke on some hosts.

    .PARAMETER Section
        Top-level config section, spelled as in the JSON (sharePoint, auth, markdown, ...).

    .PARAMETER Values
        Hashtable of property name -> value to merge into that section.

    .OUTPUTS
        String - the path written.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Section,
        [Parameter(Mandatory)][hashtable]$Values
    )

    $existing = [ordered]@{}
    if (Test-Path -LiteralPath $script:UserOverride) {
        $raw = Get-Content -LiteralPath $script:UserOverride -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($property in $raw.PSObject.Properties) {
            $inner = [ordered]@{}
            foreach ($child in $property.Value.PSObject.Properties) { $inner[$child.Name] = $child.Value }
            $existing[$property.Name] = $inner
        }
    }

    if (-not $existing.Contains($Section)) { $existing[$Section] = [ordered]@{} }
    foreach ($key in $Values.Keys) {
        $value = $Values[$key]
        if ($null -eq $value -or ("$value" -eq "" -and $value -isnot [array])) {
            if ($existing[$Section].Contains($key)) { $existing[$Section].Remove($key) }
        }
        else {
            $existing[$Section][$key] = $value
        }
    }

    if (-not $PSCmdlet.ShouldProcess($script:UserOverride, "Save configuration")) { return $script:UserOverride }

    $directory = Split-Path -Parent $script:UserOverride
    if (-not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    # Depth 10: webPartProperties nests, and the default depth of 2 would silently flatten it to
    # the literal string "System.Object[]".
    $json = [pscustomobject]$existing | ConvertTo-Json -Depth 10
    Set-Content -LiteralPath $script:UserOverride -Value $json -Encoding utf8NoBOM

    # The cached config is now stale, and the next caller would carry on with the old values.
    $script:Config = $null
    # markdownPage.componentId may have just changed, and the resolved web part was chosen by it.
    $script:ResolvedComponent = $null
    return $script:UserOverride
}
