<#
.SYNOPSIS
    MarkstrataSiteBuilder - publish a folder of Markdown files as a browsable SharePoint
    Online site, driven by editable JSON config.

.DESCRIPTION
    Root module.

    The source of truth is a SharePoint document library full of .md files - typically one
    synced to a local folder, so authors edit Markdown in the editor they already use and
    OneDrive carries the change to SharePoint. This module builds everything around those
    files:

      * ONE renderer page (Wiki.aspx) holding a single Markdown web part. Every document is
        addressed through its strataDoc query string, so the site needs one page rather than
        one page per document.
      * A category index per top-level folder and a home index, generated from the folder
        structure and regenerated on demand.
      * The site navigation: themed groups, their categories, and optionally the documents.
      * Media relocation, orphan sweeps and link conversion between page links and wiki links.

    Rendering is done by the Markstrata SharePoint Framework web part, which must be installed
    in the tenant app catalogue. This module is an independent companion to it and is not
    affiliated with its publisher.

    No secrets are stored on disk. Authentication is either interactive (delegated) or app-only
    with a certificate supplied at run time.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# --- Module-wide locations --------------------------------------------------
# Config ships with the module; a per-user override and the logs live under the user's profile
# so an installed (read-only) copy of the module never needs to be written to.
$script:AppName      = "MarkstrataSiteBuilder"
$script:ModuleRoot   = $PSScriptRoot
$script:ConfigRoot   = Join-Path $script:ModuleRoot "config"
$script:DataRoot     = Join-Path $env:LOCALAPPDATA $script:AppName
$script:LogRoot      = Join-Path (Join-Path $env:APPDATA $script:AppName) "logs"
$script:UserOverride = Join-Path $script:DataRoot "config.json"

# Cached config + session state, resolved lazily and memoised for the session.
$script:Config            = $null
$script:LogFile           = $null
$script:LogQuiet          = $false
$script:SharePointReady   = $false  # set once a PnP connection is established
$script:SharePointSite    = $null   # cached target web (Url + ServerRelativeUrl + Title)
$script:ConnectionMode    = $null   # "AppOnly" | "Interactive" - what the current session is using
$script:CategoryData      = $null   # cached { Map = @{folder->display name}; List = @(ordered) }
$script:CategoryGroupData = $null   # cached themed groups (config/category-groups.json) for the menu
$script:linkTally         = 0       # per-document link conversion counter (Convert-MarkstrataLink)

# The URL SharePoint itself stores for a navigation "Label" - a node that renders as plain text
# and only opens its children. Any other value would make a group heading clickable and land the
# visitor on a page that does not exist.
$script:LinklessHeaderUrl = "http://linkless.header/"

# --- Load functions ---------------------------------------------------------
foreach ($folder in "Private", "Public") {
    $functionDirectory = Join-Path $script:ModuleRoot $folder
    if (Test-Path $functionDirectory) {
        Get-ChildItem -Path $functionDirectory -Filter "*.ps1" -File | ForEach-Object {
            . $_.FullName
        }
    }
}

# Only the public entry points are exported (the manifest also constrains this).
Export-ModuleMember -Function @(
    # Setup and connection
    "Initialize-MarkstrataConfig"
    "Register-MarkstrataApp"
    "Connect-MarkstrataSite"
    "Disconnect-MarkstrataSite"
    "Test-MarkstrataAccess"
    # Build the site
    "New-MarkstrataRenderer"
    "New-MarkstrataIndex"
    "Publish-MarkstrataLibrary"
    "Update-MarkstrataNavigation"
    "Invoke-MarkstrataRefresh"
    # Maintain it
    "New-MarkstrataPage"
    "Update-MarkstrataPageSetting"
    "Convert-MarkstrataLink"
    "Move-MarkstrataMedia"
    "Remove-MarkstrataOrphanMedia"
    "Remove-MarkstrataLegacyPage"
)
