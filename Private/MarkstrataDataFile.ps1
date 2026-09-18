<#
    Data-folder helpers. The editable JSON files - the config override, the category list and the
    menu groups - live under %LOCALAPPDATA%\MarkstrataSiteBuilder, not in the module folder.

    An installed module is read-only in practice: a machine-wide install lands somewhere an
    ordinary user cannot write, and any install is replaced wholesale by the next update. A file
    the user is expected to edit cannot live there. config/ inside the module therefore ships
    TEMPLATES, and the first read of one copies it into the data folder for the user to edit.
#>

function Get-MarkstrataDataPath {
    <#
    .SYNOPSIS
        Where a named data file belongs under the user's profile.

    .DESCRIPTION
        A rooted path is returned untouched, so a config setting may point a data file anywhere -
        a shared folder, a repository checkout - rather than only at the data folder.

    .PARAMETER Name
        File name (categories.json) or a full path to one.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Name)

    if ([System.IO.Path]::IsPathRooted($Name)) { return $Name }
    return (Join-Path $script:DataRoot $Name)
}

function Resolve-MarkstrataDataFile {
    <#
    .SYNOPSIS
        Resolve a data file to read, seeding it from the shipped template on first use.

    .DESCRIPTION
        Returns the path in the data folder. If nothing is there yet and the module ships a
        template of that name, the template is COPIED across first, so the user has a commented
        file to edit in a place that survives a module update - and so a developer's edits in a
        repository checkout carry over the first time an installed copy runs.

        The copy is best effort. Where the profile cannot be written to, the shipped template is
        returned instead: reading a default beats failing outright, and nothing writes to it.

        The returned path may not exist - a data file with no template and no user copy is the
        normal state of an optional one. Callers test for it.

    .PARAMETER Name
        File name (categories.json) or a full path, which is returned unchanged.

    .OUTPUTS
        String - the path to read.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Name)

    # A rooted name is the caller's own path: it is not ours to seed or to second-guess.
    if ([System.IO.Path]::IsPathRooted($Name)) { return $Name }

    $dataPath = Get-MarkstrataDataPath -Name $Name
    if (Test-Path -LiteralPath $dataPath) { return $dataPath }

    $templatePath = Join-Path $script:TemplateRoot $Name
    if (-not (Test-Path -LiteralPath $templatePath)) { return $dataPath }

    try {
        if (-not (Test-Path -LiteralPath $script:DataRoot)) {
            New-Item -ItemType Directory -Path $script:DataRoot -Force | Out-Null
        }
        Copy-Item -LiteralPath $templatePath -Destination $dataPath -ErrorAction Stop
        Write-MarkstrataLog -Message "Created '$dataPath' from the shipped template. Edit that copy - the one in the module folder is a template and is replaced when the module is updated." -Level Info -Component "Config" -NoConsole
        return $dataPath
    }
    catch {
        Write-MarkstrataLog -Message "Could not create '$dataPath' ($($_.Exception.Message)). Reading the shipped template instead; edits made there are lost when the module is updated." -Level Warning -Component "Config"
        return $templatePath
    }
}
