function Get-MarkstrataCategoryGroup {
    <#
    .SYNOPSIS
        Load the themed category groups that form the menu's top level.

    .DESCRIPTION
        Twenty categories do not fit across a SharePoint header bar; most collapse into the "..."
        overflow and become invisible. The menu's top level is therefore a handful of groups, each
        opening a mega menu of its categories.

        Groups come from category-groups.json (navigation.groupFile) in file order. The file lives
        in the data folder, %LOCALAPPDATA%\MarkstrataSiteBuilder, and is seeded there from the
        module's template the first time it is read: the module folder is read-only once installed
        and is replaced on update, so an edit there would not survive. Set navigation.groupFile to
        a full path to keep the file somewhere else entirely.

        A category present in the library but missing from every group is placed in defaultGroup
        rather than dropped, so adding a category folder can never silently remove it from the menu.

        Group membership is matched on the category DISPLAY name ("Gamma & Delta"), not the folder
        slug, because that is what the config file is written in and what a human edits.

    .PARAMETER Category
        The category display names actually present. Groups with no present category are omitted, so
        an empty group never becomes a dead menu entry.

    .PARAMETER Force
        Re-read the group file instead of using the session cache.

    .OUTPUTS
        PSCustomObject[] - one per non-empty group, with Name and Categories (in config order,
        then any defaulted ones alphabetically).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [string[]]$Category = @(),

        [switch]$Force
    )

    if (-not $script:CategoryGroupData -or $Force) {
        $config = Get-MarkstrataConfig
        $groupFileName = [string](Get-OptionalProperty $config.Navigation "groupFile" "category-groups.json")
        $groupPath = Resolve-MarkstrataDataFile -Name $groupFileName
        if (-not (Test-Path -LiteralPath $groupPath)) {
            throw "Category group file not found: $groupPath. Run Initialize-MarkstrataConfig to create it, or set navigation.useGroups to false."
        }
        $script:CategoryGroupData = Get-Content -LiteralPath $groupPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $script:CategoryGroupFile = $groupPath
    }
    $groupData = $script:CategoryGroupData
    $defaultGroup = [string](Get-OptionalProperty $groupData "defaultGroup" "Reference")

    $present = [System.Collections.Generic.List[string]]::new()
    foreach ($name in ($Category | Where-Object { $_ } | Sort-Object -Unique)) { $present.Add($name) }

    $result = [System.Collections.Generic.List[object]]::new()
    $assigned = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)

    foreach ($group in @($groupData.groups)) {
        $members = [System.Collections.Generic.List[string]]::new()
        foreach ($member in @($group.categories)) {
            $match = $present | Where-Object { $_ -eq $member } | Select-Object -First 1
            if ($match) {
                $members.Add($match)
                [void]$assigned.Add($match)
            }
        }
        $result.Add([pscustomobject]@{ Name = [string]$group.name; Categories = $members })
    }

    # Anything the config never mentions lands in the default group rather than vanishing.
    # The cache may have been filled by an earlier call (or injected by the tests), so the file it
    # came from is remembered rather than re-resolved.
    $groupSource = if ($script:CategoryGroupFile) { $script:CategoryGroupFile } else { "the category group file" }
    $orphans = @($present | Where-Object { -not $assigned.Contains($_) } | Sort-Object)
    if ($orphans.Count -gt 0) {
        $target = $result | Where-Object { $_.Name -eq $defaultGroup } | Select-Object -First 1
        if (-not $target) {
            $target = [pscustomobject]@{ Name = $defaultGroup; Categories = [System.Collections.Generic.List[string]]::new() }
            $result.Add($target)
        }
        foreach ($orphan in $orphans) {
            $target.Categories.Add($orphan)
            Write-MarkstrataLog -Message "Category '$orphan' is in no group; placed in '$defaultGroup'. Add it to $groupSource to place it deliberately." -Level Warning -Component "Navigation" -NoConsole
        }
    }

    # Sort each group's categories alphabetically. The config file's order is how someone happened
    # to type them, which reads as random in a menu; a reader scanning for a category expects A-Z.
    # Both the menu and the home index take their order from here, so they cannot disagree.
    foreach ($group in $result) {
        $sorted = [System.Collections.Generic.List[string]]::new()
        foreach ($name in ($group.Categories | Sort-Object)) { $sorted.Add($name) }
        $group.Categories = $sorted
    }

    # An empty group would render as a dead menu entry.
    return @($result | Where-Object { $_.Categories.Count -gt 0 })
}
