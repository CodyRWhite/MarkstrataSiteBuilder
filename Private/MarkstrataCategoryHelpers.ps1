<#
    Category helpers. A category IS a top-level folder in the Markdown library; these turn that
    folder name into the name people see, and back again.

    SharePoint will not take "&" in a path, so a category whose name contains one has to live in a
    folder spelled differently ("Gamma & Delta" -> "Gamma and Delta"). config/categories.json
    holds the display names, in menu order, and the slug rule below is what maps between the two.
#>

function Get-MarkstrataCategoryList {
    <#
    .SYNOPSIS
        Load and cache the ordered list of category display names.

    .DESCRIPTION
        config/categories.json (categories.listFile) is a JSON array of display names, in the order
        they should appear. It is OPTIONAL: a library whose folder names are already what you want
        shown, in alphabetical order, needs no file at all - every folder then falls back to its
        own name.

    .PARAMETER Force
        Re-read from disk instead of using the session cache.

    .OUTPUTS
        PSCustomObject with List (string[] in file order).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([switch]$Force)

    if ($script:CategoryData -and -not $Force) { return $script:CategoryData }

    $config = Get-MarkstrataConfig
    $list = [System.Collections.Generic.List[string]]::new()

    $listFileName = [string](Get-OptionalProperty $config.Categories "listFile" "categories.json")
    $listPath = Join-Path $script:ConfigRoot $listFileName
    if (Test-Path -LiteralPath $listPath) {
        $raw = Get-Content -LiteralPath $listPath -Raw -Encoding UTF8 | ConvertFrom-Json
        # Accept either a bare array or an object with a "categories" array, so the file can carry
        # a "_comment" explaining itself without the loader choking on it.
        $values = if ($raw -is [array]) { $raw } else { @(Get-OptionalProperty $raw "categories" @()) }
        foreach ($value in $values) {
            if (-not [string]::IsNullOrWhiteSpace([string]$value)) { $list.Add([string]$value) }
        }
    }

    $script:CategoryData = [pscustomobject]@{ List = $list }
    return $script:CategoryData
}

function ConvertTo-CategorySlug {
    <#
    .SYNOPSIS
        Turn a category display name into the folder name that holds it.

    .DESCRIPTION
        "Gamma & Delta" -> "Gamma and Delta", "Archive (draft pages)" -> "Archive draft pages".
        The characters replaced are the ones SharePoint rejects in a path, plus "&", which it
        accepts but which then has to be escaped in every URL that reaches the file.

    .PARAMETER Category
        The category display name.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Category)

    $slug = $Category -replace "&", "and"
    $slug = $slug -replace "[()]", ""
    $slug = $slug -replace '[~"#%*:<>?/\\{|}]', "-"
    $slug = ($slug -replace "\s+", " ").Trim()
    if ([string]::IsNullOrWhiteSpace($slug)) { $slug = "General" }
    return $slug
}
