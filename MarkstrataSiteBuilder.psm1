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
# The module folder is READ-ONLY as far as this module is concerned. An installed module sits in a
# PSModulePath folder (Program Files for an AllUsers install) that an ordinary user cannot write
# to, and even where it can be written to, a module update replaces the folder wholesale - so any
# file a user is meant to edit or a command is meant to write would be either unwritable or lost.
#
# Everything editable therefore lives under the user's profile: the config override, the category
# list and the menu groups. config/ inside the module holds the shipped DEFAULTS for the main
# config file and the TEMPLATES the other two are seeded from on first use.
$script:AppName      = "MarkstrataSiteBuilder"
$script:ModuleRoot   = $PSScriptRoot
$script:TemplateRoot = Join-Path $script:ModuleRoot "config"

# %LOCALAPPDATA% and %APPDATA% are Windows; PowerShell 7 on Linux or macOS defines neither, so
# fall back to the XDG location rather than throwing on a Join-Path with an empty string.
$localAppData   = if ($env:LOCALAPPDATA)  { $env:LOCALAPPDATA }
                  elseif ($env:XDG_DATA_HOME) { $env:XDG_DATA_HOME }
                  else { Join-Path $HOME ".local/share" }
$roamingAppData = if ($env:APPDATA) { $env:APPDATA } else { $localAppData }

$script:DataRoot     = Join-Path $localAppData $script:AppName
$script:LogRoot      = Join-Path (Join-Path $roamingAppData $script:AppName) "logs"
$script:UserOverride = Join-Path $script:DataRoot "config.json"

# Cached config + session state, resolved lazily and memoised for the session.
$script:Config            = $null
$script:LogFile           = $null
$script:LogQuiet          = $false
$script:SharePointReady   = $false  # set once a PnP connection is established
$script:SharePointSite    = $null   # cached target web (Url + ServerRelativeUrl + Title)
$script:ConnectionMode    = $null   # "AppOnly" | "Interactive" - what the current session is using
$script:CategoryData      = $null   # cached { Map = @{folder->display name}; List = @(ordered) }
$script:CategoryGroupData = $null   # cached themed groups (category-groups.json, in the data folder)
$script:CategoryGroupFile = $null   # path the cached groups were read from, for messages
$script:ResolvedComponent = $null   # cached web part object (markdownPage.componentId) for this site
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
