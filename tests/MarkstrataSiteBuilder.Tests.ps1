#requires -Module Pester
<#
    Offline unit tests. Nothing here touches SharePoint: the PnP half is exercised only through
    its public surface, since it is entirely round-trips to a live site.

    Every name below is invented. Categories are "Alpha", "Beta", "Gamma & Delta" and
    "Epsilon & Zeta", menu groups are "Group One" through "Group Three", documents are "Page One"
    and "Sample Report", and hosts are contoso.sharepoint.com or example.com. That is deliberate:
    a test suite carrying real category names, real menu groups, real page titles or real image
    names from whichever site the tool was first pointed at publishes them to everyone who reads
    the repository, and it reads as though the builder were made for that one site. Keep new
    fixtures in the same invented vocabulary.

    Every test runs against a FIXED configuration injected into module scope below, not against
    the shipped config file and not against whatever the person running the tests happens to have
    in their user override. Otherwise a passing suite would say more about the developer's tenant
    than about the code.

    Run:  Invoke-Pester -Path .\tests
#>

BeforeAll {
    $ModuleRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $ModuleRoot 'MarkstrataSiteBuilder.psd1') -Force
    $script:Module = Get-Module MarkstrataSiteBuilder

    $fixture = [pscustomobject]@{
        SharePoint = [pscustomobject]@{
            siteUrl        = 'https://contoso.sharepoint.com/sites/docs'
            pagesLibrary   = 'Site Pages'
            categoryColumn = ''
        }
        Auth = [pscustomobject]@{
            clientId = ''; tenantId = ''; certificateThumbprint = ''
            appDisplayName = 'MarkstrataSiteBuilder'; sitePermission = 'Manage'
        }
        Run = [pscustomobject]@{ batchSize = 50; dryRun = $false }
        Categories = [pscustomobject]@{ enabled = $true; listFile = 'categories.json' }
        Navigation = [pscustomobject]@{
            location = 'QuickLaunch'; includeHome = $true; useGroups = $true
            groupFile = 'category-groups.json'; includePages = $false; megaMenu = $true
            pruneFooter = $true; useRendererLinks = $true
        }
        Markdown = [pscustomobject]@{
            libraryRoot              = (Join-Path $TestDrive 'library')
            libraryServerRelativeUrl = '/sites/docs/Shared Documents'
            documentLibrary          = 'Documents'
            mediaFolder              = '_media'
            useWikiLinks             = $true
            imageUrlBase             = ''
            legacyMediaLibrary       = ''
            overwriteExisting        = $false
        }
        MarkdownPage = [pscustomobject]@{
            componentName     = 'Markstrata'
            componentId       = '74aecd51-7619-4ca6-b81a-6c670d6098b3'
            rendererPage      = 'Wiki.aspx'
            strataDocEncoding = 'none'
            layoutType        = 'SingleWebPartAppPage'
            pageRootFolder    = 'Docs'
            publish           = $true
            overwriteExisting = $true
            webPartProperties = [pscustomobject]@{ contentSource = 'library'; fileUrl = '' }
        }
        MarkdownIndex = [pscustomobject]@{
            enabled      = $true
            homeFileName = 'Home.md'
            indexFileName = '{Category}.md'
            homeTitle    = 'Documentation'
            homeIntro    = ''
            backLinkText = 'Back to the home page'
        }
    }

    # Category display names and menu groups, injected the same way and for the same reason.
    $categories = [System.Collections.Generic.List[string]]::new()
    foreach ($name in 'Alpha', 'Beta', 'Gamma & Delta', 'Epsilon & Zeta') { $categories.Add($name) }
    $groupData = @'
{
  "defaultGroup": "Other",
  "groups": [
    { "name": "Group One",   "categories": ["Alpha"] },
    { "name": "Group Two",   "categories": ["Beta"] },
    { "name": "Group Three", "categories": ["Gamma & Delta", "Epsilon & Zeta"] }
  ]
}
'@ | ConvertFrom-Json

    & $script:Module {
        param($Config, $Categories, $Groups)
        $script:Config            = $Config
        $script:CategoryData      = [pscustomobject]@{ List = $Categories }
        $script:CategoryGroupData = $Groups
    } $fixture $categories $groupData
}

Describe 'Public surface includes the Markdown pipeline' {
    It 'exports every documented command' {
        $exported = (Get-Command -Module MarkstrataSiteBuilder).Name
        foreach ($name in 'Initialize-MarkstrataConfig', 'Register-MarkstrataApp',
            'Connect-MarkstrataSite', 'Disconnect-MarkstrataSite', 'Test-MarkstrataAccess',
            'New-MarkstrataRenderer', 'New-MarkstrataIndex', 'Publish-MarkstrataLibrary',
            'Update-MarkstrataNavigation', 'Invoke-MarkstrataRefresh', 'New-MarkstrataPage',
            'Update-MarkstrataPageSetting', 'Convert-MarkstrataLink', 'Move-MarkstrataMedia',
            'Remove-MarkstrataOrphanMedia', 'Remove-MarkstrataLegacyPage') {
            $exported | Should -Contain $name
        }
    }

    It 'exports nothing beyond what the manifest lists' {
        $manifest = Import-PowerShellDataFile (Join-Path (Split-Path -Parent $PSScriptRoot) 'MarkstrataSiteBuilder.psd1')
        $exported = @((Get-Command -Module MarkstrataSiteBuilder).Name | Sort-Object)
        $exported | Should -Be @($manifest.FunctionsToExport | Sort-Object)
    }

    It 'ships a config that names no tenant, site or library' {
        # A shipped default pointing at somebody's real site is how a public tool ends up
        # publishing to the wrong place on a first run.
        $shipped = Get-Content (Join-Path (Split-Path -Parent $PSScriptRoot) 'config/MarkstrataSiteBuilder.config.json') -Raw | ConvertFrom-Json
        $shipped.sharePoint.siteUrl   | Should -BeNullOrEmpty
        $shipped.markdown.libraryRoot | Should -BeNullOrEmpty
        $shipped.auth.clientId        | Should -BeNullOrEmpty
        $shipped.markdownPage.webPartProperties.contentSource | Should -Be 'library'
    }

    It 'ships no category list and no populated menu groups' {
        # The category list and the menu groups describe one organisation: its departments, the
        # way it divides its documentation. Shipping either would leak that and build a stranger's
        # menu out of somebody else's org chart.
        $configRoot = Join-Path (Split-Path -Parent $PSScriptRoot) 'config'
        $categories = Get-Content (Join-Path $configRoot 'categories.json') -Raw | ConvertFrom-Json
        # Either shape is accepted by the loader: a bare array, or an object carrying a "_comment".
        $listed = if ($categories -is [array]) { $categories } else { @($categories.categories) }
        @($listed).Count | Should -Be 0

        $groups = Get-Content (Join-Path $configRoot 'category-groups.json') -Raw | ConvertFrom-Json
        foreach ($group in $groups.groups) {
            @($group.categories).Count | Should -Be 0
        }
    }
}

Describe 'Markdown path helpers' {
    It 'builds the page URL under the configured page root folder' {
        $url = & $script:Module { Get-MarkdownPageServerRelativeUrl -Folder 'Alpha' -LeafName 'Page One' }
        $url | Should -Be '/sites/docs/SitePages/Docs/Alpha/Page One.aspx'
    }

    It 'builds the Markdown file URL inside the document library' {
        $url = & $script:Module { Get-MarkdownFileServerRelativeUrl -Folder 'Alpha' -FileName 'Page One.md' }
        $url | Should -Be '/sites/docs/Shared Documents/Alpha/Page One.md'
    }

    It 'replaces characters SharePoint will not accept in a leaf name' {
        $leaf = & $script:Module { ConvertTo-SafeLeafName -Name 'A/B: what? <now>' }
        $leaf | Should -Not -Match '[\\/:*?"<>|#%]'
        $leaf | Should -Not -BeNullOrEmpty
    }
}

Describe 'Markdown category helpers' {
    It 'maps a folder slug back to its display name' {
        $name = & $script:Module { Get-MarkdownCategoryDisplayName -FolderSlug 'Gamma and Delta' }
        $name | Should -Be 'Gamma & Delta'
    }

    It 'returns an unknown folder as its own display name' {
        $name = & $script:Module { Get-MarkdownCategoryDisplayName -FolderSlug 'Some New Folder' }
        $name | Should -Be 'Some New Folder'
    }

    It 'orders known categories by categories.json and appends unknown folders A-Z' {
        $ordered = & $script:Module {
            Get-MarkdownCategoryOrder -FolderSlug @('Zulu', 'Beta', 'Kilo', 'Alpha')
        }
        # Alpha precedes Beta in categories.json; the unknowns follow, alphabetically.
        $ordered[0] | Should -Be 'Alpha'
        $ordered[1] | Should -Be 'Beta'
        $ordered[2] | Should -Be 'Kilo'
        $ordered[3] | Should -Be 'Zulu'
    }

    It 'percent-encodes a URL for use as a Markdown link destination' {
        $url = & $script:Module { ConvertTo-MarkdownLinkUrl -Url '/sites/docs/SitePages/Docs/Gamma and Delta/Index.aspx' }
        $url | Should -Not -Match ' '
        $url | Should -Match 'Gamma%20and%20Delta'
    }
}

Describe 'New-MarkstrataIndex' {
    BeforeAll {
        $script:IndexRoot = Join-Path $TestDrive 'library'
        foreach ($folder in 'Alpha', 'Beta') {
            New-Item -ItemType Directory -Force -Path (Join-Path $script:IndexRoot $folder) | Out-Null
        }
        Set-Content -LiteralPath (Join-Path $script:IndexRoot 'Alpha\Page One.md') -Value '# Page One' -Encoding utf8NoBOM
        Set-Content -LiteralPath (Join-Path $script:IndexRoot 'Alpha\Page Two.md') -Value '# Page Two' -Encoding utf8NoBOM
        Set-Content -LiteralPath (Join-Path $script:IndexRoot 'Beta\Page Three.md') -Value '# Page Three' -Encoding utf8NoBOM

        $script:IndexResult = New-MarkstrataIndex -LibraryRoot $script:IndexRoot
    }

    It 'writes one index per category plus the home index' {
        $script:IndexResult.Categories | Should -Be 2
        $script:IndexResult.Documents  | Should -Be 3
        Test-Path (Join-Path $script:IndexRoot 'Home.md')      | Should -BeTrue
        # The index is named after its folder, not a fixed "Index.md".
        Test-Path (Join-Path $script:IndexRoot 'Alpha\Alpha.md') | Should -BeTrue
        Test-Path (Join-Path $script:IndexRoot 'Beta\Beta.md')   | Should -BeTrue
        Test-Path (Join-Path $script:IndexRoot 'Alpha\Index.md') | Should -BeFalse
    }

    It 'titles a category index with the display name and lists its documents as page links' {
        $content = Get-Content (Join-Path $script:IndexRoot 'Alpha\Alpha.md') -Raw
        $content | Should -Match '(?m)^# Alpha$'
        $content | Should -Match '\[\[Page One\]\]'
        $content | Should -Match '\[\[Page Two\]\]'
        $content | Should -Match 'Back to the home page'
    }

    It 'lists every category on the home index, linked to its index page' {
        $content = Get-Content (Join-Path $script:IndexRoot 'Home.md') -Raw
        $content | Should -Match '(?m)^# Documentation$'
        $content | Should -Match '(?m)^- \[\[Alpha/Alpha\|Alpha\]\]$'
        $content | Should -Match '(?m)^- \[\[Beta/Beta\|Beta\]\]$'
    }

    It 'keeps the indexes plain - no document counts, which go stale' {
        $homeText = Get-Content (Join-Path $script:IndexRoot 'Home.md') -Raw
        $categoryText = Get-Content (Join-Path $script:IndexRoot 'Alpha\Alpha.md') -Raw
        foreach ($text in $homeText, $categoryText) {
            $text | Should -Not -Match '\d+\s+document'
            $text | Should -Not -Match '(?m)^\|'          # no tables
            $text | Should -Not -Match 'categor(y|ies)\.$'
        }
    }

    It 'never lists an index file as one of its own documents' {
        # Re-running must not pick up the index written by the first run.
        New-MarkstrataIndex -LibraryRoot $script:IndexRoot | Out-Null
        $content = Get-Content (Join-Path $script:IndexRoot 'Alpha\Alpha.md') -Raw
        $content | Should -Not -Match '(?m)^- \[\[Alpha\]\]'
        @(($content -split "`n") | Where-Object { $_ -match '^- \[' }).Count | Should -Be 2
    }

    It 'exports the index and navigation commands' {
        $exported = (Get-Command -Module MarkstrataSiteBuilder).Name
        $exported | Should -Contain 'New-MarkstrataIndex'
        $exported | Should -Contain 'Update-MarkstrataNavigation'
    }
}

Describe 'Get-MarkstrataCategoryGroup' {
    # Groups come from the fixture: Group One = Alpha, Group Two = Beta,
    # Group Three = Gamma & Delta + Epsilon & Zeta, everything else -> Other.

    It 'places every present category into some group' {
        $categories = @('Alpha', 'Beta', 'Gamma & Delta', 'Epsilon & Zeta')
        $groups = & $script:Module { param($Cats) Get-MarkstrataCategoryGroup -Category $Cats } $categories
        (($groups | ForEach-Object { $_.Categories.Count } | Measure-Object -Sum).Sum) | Should -Be $categories.Count
    }

    It 'keeps the top level small enough to fit the header bar' {
        # More than about six entries and SharePoint hides the rest behind a "..." overflow.
        $categories = @('Alpha', 'Beta', 'Gamma & Delta', 'Epsilon & Zeta')
        $groups = & $script:Module { param($Cats) Get-MarkstrataCategoryGroup -Category $Cats } $categories
        @($groups).Count | Should -BeLessOrEqual 7
    }

    It 'omits a group whose categories are all absent' {
        $groups = & $script:Module { Get-MarkstrataCategoryGroup -Category @('Alpha') }
        @($groups).Count | Should -Be 1
        $groups[0].Name | Should -Be 'Group One'
    }

    It 'puts an unknown category in the default group rather than dropping it' {
        # Adding a folder must never silently remove it from the menu.
        $groups = & $script:Module { Get-MarkstrataCategoryGroup -Category @('Alpha', 'Brand New Category') }
        $placed = $groups | ForEach-Object { $_.Categories }
        $placed | Should -Contain 'Brand New Category'
    }

    It 'sorts each group alphabetically, whatever order the config listed them in' {
        $groups = & $script:Module { Get-MarkstrataCategoryGroup -Category @('Gamma & Delta', 'Epsilon & Zeta') }
        $third = $groups | Where-Object { $_.Name -eq 'Group Three' }
        @($third.Categories)[0] | Should -Be 'Epsilon & Zeta'
    }
}


Describe 'New-MarkstrataIndex nested folders' {
    BeforeAll {
        $script:NestRoot = Join-Path $TestDrive 'nested'
        New-Item -ItemType Directory -Force -Path (Join-Path $script:NestRoot 'Alpha\Section\Subsection') | Out-Null
        Set-Content -LiteralPath (Join-Path $script:NestRoot 'Alpha\Page One.md') -Value '# a' -Encoding utf8NoBOM
        Set-Content -LiteralPath (Join-Path $script:NestRoot 'Alpha\Section\Page Two.md') -Value '# b' -Encoding utf8NoBOM
        Set-Content -LiteralPath (Join-Path $script:NestRoot 'Alpha\Section\Subsection\Page Three.md') -Value '# c' -Encoding utf8NoBOM

        $script:NestResult = New-MarkstrataIndex -LibraryRoot $script:NestRoot
        $script:NestIndex = Get-Content (Join-Path $script:NestRoot 'Alpha\Alpha.md') -Raw
    }

    It 'counts nested documents as part of their top-level category' {
        # One category, not three: Section and Subsection are sections inside Alpha.
        $script:NestResult.Categories | Should -Be 1
        $script:NestResult.Documents  | Should -Be 3
    }

    It 'writes one index for the category, not one per nested folder' {
        Test-Path (Join-Path $script:NestRoot 'Alpha\Alpha.md')                        | Should -BeTrue
        Test-Path (Join-Path $script:NestRoot 'Alpha\Section\Section.md')              | Should -BeFalse
        Test-Path (Join-Path $script:NestRoot 'Alpha\Section\Subsection\Subsection.md') | Should -BeFalse
    }

    It 'lists nested documents under a section heading, with their full path in the URL' {
        $script:NestIndex | Should -Match '(?m)^## Section$'
        $script:NestIndex | Should -Match '(?m)^## Section / Subsection$'
        $script:NestIndex | Should -Match '\[\[Section/Subsection/Page Three\|Page Three\]\]'
    }

    It 'lists the category own documents before any section' {
        $ownIndex = $script:NestIndex.IndexOf('Page One')
        $sectionIndex = $script:NestIndex.IndexOf('## Section')
        $ownIndex | Should -BeLessThan $sectionIndex
    }

    It 'labels a subfolder link with the page name, not the whole path' {
        # Without a pipe the web part renders the entire target as the link text.
        $script:NestIndex | Should -Not -Match '\[\[Section/Subsection/Page Three\]\]'
        $script:NestIndex | Should -Match '\|Page Three\]\]'
    }

    It 'leaves no double blank line before the back link' {
        $script:NestIndex | Should -Not -Match "`n`n`n"
    }
}

Describe 'New-MarkstrataIndex grouping' {
    BeforeAll {
        $script:GroupRoot = Join-Path $TestDrive 'grouped'
        foreach ($folder in 'Alpha', 'Beta', 'Unlisted Category') {
            New-Item -ItemType Directory -Force -Path (Join-Path $script:GroupRoot $folder) | Out-Null
        }
        Set-Content -LiteralPath (Join-Path $script:GroupRoot 'Alpha\Page One.md') -Value '# a' -Encoding utf8NoBOM
        Set-Content -LiteralPath (Join-Path $script:GroupRoot 'Beta\Page Two.md') -Value '# b' -Encoding utf8NoBOM
        Set-Content -LiteralPath (Join-Path $script:GroupRoot 'Unlisted Category\Note.md') -Value '# c' -Encoding utf8NoBOM
        New-MarkstrataIndex -LibraryRoot $script:GroupRoot | Out-Null
        $script:HomeText = Get-Content (Join-Path $script:GroupRoot 'Home.md') -Raw
    }

    It 'writes a heading per group on the home index' {
        $script:HomeText | Should -Match '(?m)^## Group One$'
        $script:HomeText | Should -Match '(?m)^## Group Two$'
    }

    It 'lists each category under its own group heading' {
        $script:HomeText | Should -Match '(?s)## Group One.*?\[\[Alpha/Alpha\|Alpha\]\]'
        $script:HomeText | Should -Match '(?s)## Group Two.*?\[\[Beta/Beta\|Beta\]\]'
    }

    It 'gives a category no group mentions a heading of its own rather than dropping it' {
        $script:HomeText | Should -Match '(?m)^## Other$'
        $script:HomeText | Should -Match ([regex]::Escape('[[Unlisted Category/Unlisted Category|'))
    }

    It 'links every category to its index' {
        foreach ($category in 'Alpha', 'Beta', 'Unlisted Category') {
            $script:HomeText | Should -Match ([regex]::Escape("[[$category/$category|"))
        }
    }
}


Describe 'Get-MarkstrataMediaRenamePlan' {
    BeforeAll {
        $script:MediaRoot = Join-Path $TestDrive 'media'
        New-Item -ItemType Directory -Force -Path (Join-Path $script:MediaRoot 'Alpha') | Out-Null
        New-Item -ItemType Directory -Force -Path (Join-Path $script:MediaRoot 'Beta') | Out-Null

        Set-Content -Encoding utf8NoBOM -LiteralPath (Join-Path $script:MediaRoot 'Alpha\Sample Report.md') -Value @'
# Sample Report

![Figure 01](/sites/docs/Old%20Images/Sample01.PNG)
![Figure 02](/sites/docs/Old%20Images/Sample02.PNG)
![Figure 01](/sites/docs/Old%20Images/Sample01.PNG)
'@
        Set-Content -Encoding utf8NoBOM -LiteralPath (Join-Path $script:MediaRoot 'Beta\Second Report.md') -Value @'
# Second Report

![Panel layout - detail view](/sites/docs/Old%20Images/Picture_1_(Small).jpg)
![](/sites/docs/Old%20Images/NoAltText.png)
![External](https://example.com/remote.png)
'@
        $script:Plan = @(& $script:Module { param($R) Get-MarkstrataMediaRenamePlan -LibraryRoot $R } $script:MediaRoot)
    }

    It 'names a file from its document and its alt text' {
        ($script:Plan | Where-Object SourceFile -eq 'Sample01.PNG').TargetName |
            Should -Be 'sample-report-figure-01.png'
    }

    It 'rescues a meaningless MediaWiki name using the alt text' {
        ($script:Plan | Where-Object SourceFile -eq 'Picture_1_(Small).jpg').TargetName |
            Should -Be 'second-report-panel-layout-detail-view.jpg'
    }

    It 'reads a destination containing balanced parentheses whole' {
        # A naive [^)]+ pattern truncates at "(Small" and loses the extension.
        $script:Plan.SourceFile | Should -Contain 'Picture_1_(Small).jpg'
    }

    It 'emits one target per document and file, not per reference' {
        # Sample01 is referenced twice in the same document.
        @($script:Plan | Where-Object SourceFile -eq 'Sample01.PNG').Count | Should -Be 1
    }

    It 'falls back to the original name when there is no alt text' {
        ($script:Plan | Where-Object SourceFile -eq 'NoAltText.png').TargetName |
            Should -Be 'second-report-noalttext.png'
    }

    It 'ignores external images' {
        $script:Plan.SourceFile | Should -Not -Contain 'remote.png'
    }

    It 'produces lowercase, hyphenated, collision-free names' {
        foreach ($entry in $script:Plan) {
            $entry.TargetName | Should -MatchExactly '^[a-z0-9.-]+$'
            $entry.TargetName | Should -Not -Match '--'
        }
        @($script:Plan | Group-Object TargetName | Where-Object Count -gt 1).Count | Should -Be 0
    }

    It 'exports the attachment commands' {
        $exported = (Get-Command -Module MarkstrataSiteBuilder).Name
        $exported | Should -Contain 'Move-MarkstrataMedia'
        $exported | Should -Contain 'Remove-MarkstrataOrphanMedia'
    }
}

Describe 'Get-MarkdownIndexFileName' {
    It 'names a category index after its own folder, case preserved' {
        & $script:Module { Get-MarkdownIndexFileName -Folder 'Alpha' }           | Should -Be 'Alpha.md'
        & $script:Module { Get-MarkdownIndexFileName -Folder 'Gamma and Delta' } | Should -Be 'Gamma and Delta.md'
    }

    It 'uses the deepest segment of a nested folder' {
        # [-1] on a bare string is its last CHARACTER, so a single-segment folder must not split
        # into one: "Alpha" would otherwise produce "a.md".
        & $script:Module { Get-MarkdownIndexFileName -Folder 'Alpha/Section/Subsection' } | Should -Be 'Subsection.md'
    }
}

Describe 'Get-MarkdownRendererUrl' {
    It 'points at the single renderer page with a strataDoc query string' {
        $url = & $script:Module { Get-MarkdownRendererUrl -Folder 'Alpha' -FileName 'Alpha.md' }
        $url | Should -Match '/SitePages/Wiki\.aspx\?strataDoc='
        # The value is library-relative: the web part already knows its library.
        $url | Should -Not -Match 'Shared(%20| )Documents'
        $url | Should -Match 'strataDoc=Alpha/Alpha\.md$'
    }

    It 'returns the bare page URL for the home index - it is the base URL' {
        # The renderer's own selectedFile IS the home index, so ?strataDoc=Home.md would ask for
        # exactly what the page already shows.
        $url = & $script:Module { Get-MarkdownRendererUrl -Folder '' -FileName 'Home.md' }
        $url | Should -Match '/SitePages/Wiki\.aspx$'
        $url | Should -Not -Match 'strataDoc'
    }

    It 'always encodes the three characters that break a query string' {
        # & splits the query, # is taken as the page fragment, + decodes to a space.
        # The first two fail SILENTLY, so this must hold in every encoding mode.
        foreach ($case in @(
            @{ Folder = 'Gamma & Delta'; File = 'Gamma and Delta.md'; Bad = '&' }
            @{ Folder = 'Alpha';         File = 'Notes # Draft.md';   Bad = '#' }
            @{ Folder = 'Alpha';         File = 'C++ Build.md';       Bad = '+' }
        )) {
            $url = & $script:Module {
                param($F, $N) Get-MarkdownRendererUrl -Folder $F -FileName $N
            } $case.Folder $case.File

            $query = $url.Substring($url.IndexOf('strataDoc=') + 10)
            $query | Should -Not -Match ([regex]::Escape($case.Bad))
        }
    }

    It 'escapes a literal percent before introducing its own escapes' {
        $url = & $script:Module { Get-MarkdownRendererUrl -Folder 'Alpha' -FileName '100% Uptime.md' }
        $url | Should -Match 'Alpha/100%25(%20| )Uptime\.md$'
    }
}

Describe 'Convert-MarkstrataLink' {
    BeforeAll {
        $script:LinkRoot = Join-Path $TestDrive 'links'
        New-Item -ItemType Directory -Force -Path (Join-Path $script:LinkRoot 'Alpha\Section') | Out-Null
        New-Item -ItemType Directory -Force -Path (Join-Path $script:LinkRoot 'Beta') | Out-Null
        Set-Content -Encoding utf8NoBOM -LiteralPath (Join-Path $script:LinkRoot 'Alpha\Section\Page One.md') -Value '# Page One'
        Set-Content -Encoding utf8NoBOM -LiteralPath (Join-Path $script:LinkRoot 'Beta\Page Two.md') -Value '# Page Two'
        $script:Subject = Join-Path $script:LinkRoot 'Beta\Subject.md'
    }

    BeforeEach {
        Set-Content -Encoding utf8NoBOM -LiteralPath $script:Subject -Value @'
# Subject

- [Read Page One](/sites/docs/SitePages/Docs/Alpha/Section/Page%20One.aspx)
- [Page Two](/sites/docs/SitePages/Docs/Beta/Page%20Two.aspx)
- [Gone](/sites/docs/SitePages/Docs/Beta/Does%20Not%20Exist.aspx)
- ![A picture](/sites/docs/Shared%20Documents/_media/sample-diagram.png)
- [External](https://example.com/page.aspx)
'@
    }

    It 'converts a page link to a wiki link' {
        Convert-MarkstrataLink -UseWikiLinks -LibraryRoot $script:LinkRoot | Out-Null
        $text = Get-Content $script:Subject -Raw
        $text | Should -Match '\[\[\.\./Alpha/Section/Page One\|Read Page One\]\]'
    }

    It 'drops the pipe when the display text is just the document name' {
        Convert-MarkstrataLink -UseWikiLinks -LibraryRoot $script:LinkRoot | Out-Null
        (Get-Content $script:Subject -Raw) | Should -Match '\[\[Page Two\]\]'
    }

    It 'leaves a link alone when the target document does not exist' {
        $result = Convert-MarkstrataLink -UseWikiLinks -LibraryRoot $script:LinkRoot
        $text = Get-Content $script:Subject -Raw
        # Turning a working page link into a broken wiki link would be worse than leaving it.
        $text | Should -Match '\[Gone\]\(/sites/docs/SitePages/Docs/Beta/Does%20Not%20Exist\.aspx\)'
        $result.Unresolved | Should -Not -BeNullOrEmpty
    }

    It 'never touches an image reference' {
        Convert-MarkstrataLink -UseWikiLinks -LibraryRoot $script:LinkRoot | Out-Null
        (Get-Content $script:Subject -Raw) | Should -Match '!\[A picture\]\(/sites/docs/Shared%20Documents/_media/sample-diagram\.png\)'
    }

    It 'never touches an external link' {
        Convert-MarkstrataLink -UseWikiLinks -LibraryRoot $script:LinkRoot | Out-Null
        (Get-Content $script:Subject -Raw) | Should -Match '\[External\]\(https://example\.com/page\.aspx\)'
    }

    It 'round-trips back to page links' {
        Convert-MarkstrataLink -UseWikiLinks -LibraryRoot $script:LinkRoot | Out-Null
        Convert-MarkstrataLink -UsePageLinks -LibraryRoot $script:LinkRoot | Out-Null
        $text = Get-Content $script:Subject -Raw
        $text | Should -Match '\[Read Page One\]\(/sites/docs/SitePages/Docs/Alpha/Section/Page%20One\.aspx\)'
        $text | Should -Not -Match '\[\['
    }
}

Describe 'Editable files live under the user profile' {
    # An installed module folder is read-only in practice - a machine-wide install is not writable
    # by the person running the commands, and any install is replaced by the next update. Every
    # file the user edits, and every file a command writes, therefore belongs in the data folder.
    BeforeAll {
        $script:DataProbe    = Join-Path $TestDrive 'appdata'
        $script:SavedState   = & $script:Module {
            [pscustomobject]@{
                DataRoot     = $script:DataRoot
                UserOverride = $script:UserOverride
                Config       = $script:Config
                CategoryData = $script:CategoryData
            }
        }
        & $script:Module {
            param($Root)
            $script:DataRoot     = $Root
            $script:UserOverride = Join-Path $Root 'config.json'
        } $script:DataProbe
    }

    AfterAll {
        & $script:Module {
            param($State)
            $script:DataRoot     = $State.DataRoot
            $script:UserOverride = $State.UserOverride
            $script:Config       = $State.Config
            $script:CategoryData = $State.CategoryData
        } $script:SavedState
    }

    It 'seeds a missing data file into the data folder, leaving the shipped template alone' {
        $template = Join-Path (Split-Path -Parent $PSScriptRoot) 'config/category-groups.json'
        $before = Get-Content -LiteralPath $template -Raw

        $resolved = & $script:Module { Resolve-MarkstrataDataFile -Name 'category-groups.json' }

        $resolved | Should -Be (Join-Path $script:DataProbe 'category-groups.json')
        Test-Path -LiteralPath $resolved | Should -BeTrue
        (Get-Content -LiteralPath $template -Raw) | Should -Be $before
    }

    It 'leaves a file the user has already edited exactly as it is' {
        New-Item -ItemType Directory -Force -Path $script:DataProbe | Out-Null
        $path = Join-Path $script:DataProbe 'categories.json'
        Set-Content -LiteralPath $path -Value '["Alpha","Beta"]' -Encoding utf8NoBOM

        $resolved = & $script:Module { Resolve-MarkstrataDataFile -Name 'categories.json' }

        $resolved | Should -Be $path
        (Get-Content -LiteralPath $path -Raw) | Should -Match 'Alpha'
    }

    It 'reads the category list from the data folder rather than the module folder' {
        New-Item -ItemType Directory -Force -Path $script:DataProbe | Out-Null
        Set-Content -LiteralPath (Join-Path $script:DataProbe 'categories.json') `
            -Value '["Omega","Sigma"]' -Encoding utf8NoBOM

        $list = & $script:Module { (Get-MarkstrataCategoryList -Force).List }

        @($list) | Should -Be @('Omega', 'Sigma')
    }

    It 'honours a full path, so a data file can be kept anywhere' {
        # A shared team copy, or a repository checkout, rather than the data folder.
        $elsewhere = Join-Path $TestDrive 'elsewhere/categories.json'
        $resolved = & $script:Module { param($Path) Resolve-MarkstrataDataFile -Name $Path } $elsewhere
        $resolved | Should -Be $elsewhere
    }

    It 'writes settings, nested ones included, to the override in the data folder' {
        # What Update-MarkstrataPageSetting -UpdateConfig records. It used to rewrite the shipped
        # config inside the module folder, which an installed module cannot write to.
        & $script:Module {
            Set-MarkstrataUserConfig -Section 'markdownPage' -Values @{
                webPartProperties = [pscustomobject]@{ contentSource = 'library'; theme = 'dark' }
            } -Confirm:$false | Out-Null
        }

        $overridePath = Join-Path $script:DataProbe 'config.json'
        Test-Path -LiteralPath $overridePath | Should -BeTrue
        $written = Get-Content -LiteralPath $overridePath -Raw | ConvertFrom-Json
        $written.markdownPage.webPartProperties.theme | Should -Be 'dark'
    }

    It 'names the module folder only where the shipped defaults are read' {
        # A regression guard: anything else touching the module folder is a file the user is
        # expected to edit, or a write, in a place that will not survive an update.
        $root = Split-Path -Parent $PSScriptRoot
        $referring = Get-ChildItem -Path (Join-Path $root 'Public'), (Join-Path $root 'Private') -Filter '*.ps1' -File |
            Where-Object { (Get-Content -LiteralPath $_.FullName -Raw) -match '\$script:(ModuleRoot|TemplateRoot)' } |
            ForEach-Object { $_.Name } | Sort-Object

        @($referring) | Should -Be @('Get-MarkstrataConfig.ps1', 'MarkstrataDataFile.ps1')
    }
}

AfterAll {
    Remove-Module MarkstrataSiteBuilder -ErrorAction SilentlyContinue
}
