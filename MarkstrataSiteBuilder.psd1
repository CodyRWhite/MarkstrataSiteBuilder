#
# Module manifest for module 'MarkstrataSiteBuilder'
#

@{

    # Script module or binary module file associated with this manifest.
    RootModule        = 'MarkstrataSiteBuilder.psm1'

    # Version number of this module.
    ModuleVersion     = '1.2.0'

    # ID used to uniquely identify this module
    GUID              = 'c7f0a9b4-3d21-4a6e-9f18-2b5c6d8e4a10'

    # Author of this module
    Author            = 'CodyRWhite'

    # Company or vendor of this module
    CompanyName       = ''

    # Copyright statement for this module
    Copyright         = 'MIT licensed. See LICENSE.'

    # Description of the functionality provided by this module
    Description       = 'Publishes a SharePoint Online document library full of Markdown files as a browsable site: one renderer page serving every document through a query string, generated category and home indexes, and a themed navigation menu built from the folder structure. Rendering is done by the Markstrata SharePoint Framework web part; this is an independent companion tool and is not affiliated with its publisher. Includes a first-run bootstrap that creates the Entra ID app registration it signs in with.'

    # Minimum version of the PowerShell engine required by this module
    PowerShellVersion = '7.2'

    # Modules that must be imported into the global environment prior to importing this module
    RequiredModules   = @('PnP.PowerShell')

    # Functions to export from this module, for best performance, do not use wildcards and do not delete the entry, use an empty array if there are no functions to export.
    FunctionsToExport = 'Initialize-MarkstrataConfig', 'Register-MarkstrataApp',
    'Connect-MarkstrataSite', 'Disconnect-MarkstrataSite',
    'Test-MarkstrataAccess',
    'New-MarkstrataRenderer', 'New-MarkstrataIndex',
    'Publish-MarkstrataLibrary', 'Update-MarkstrataNavigation',
    'Invoke-MarkstrataRefresh',
    'New-MarkstrataPage', 'Update-MarkstrataPageSetting',
    'Convert-MarkstrataLink',
    'Move-MarkstrataMedia', 'Remove-MarkstrataOrphanMedia',
    'Remove-MarkstrataLegacyPage'

    # Cmdlets to export from this module.
    CmdletsToExport   = @()

    # Variables to export from this module.
    VariablesToExport = @()

    # Aliases to export from this module.
    AliasesToExport   = @()

    # Private data to pass to the module specified in RootModule/ModuleToProcess.
    PrivateData       = @{

        PSData = @{

            # Tags applied to this module. These help with module discovery in online galleries.
            Tags         = 'SharePoint', 'SharePointOnline', 'Markdown', 'Markstrata', 'PnP',
            'Documentation', 'Wiki', 'M365', 'Publishing'

            # A URL to the license for this module.
            LicenseUri   = ''

            # A URL to the main website for this project.
            ProjectUri   = ''

            # ReleaseNotes of this module
            ReleaseNotes = @'
1.2.0
- Pages no longer publish blank: the web part is resolved by componentId to a
  component object and every page is verified to carry it. The package now
  installs more than one component, and a display name matched neither.
- A partial user override no longer discards the nested keys beside it.
- The orphan sweep no longer recycles the renderer page.
- Test-MarkstrataAccess checks the configured component against the site with
  the cmdlet that still exists.
- Link conversion leaves fenced and inline code alone.

1.1.0
- categories.json and category-groups.json are read from, and created in,
  %LOCALAPPDATA%\MarkstrataSiteBuilder. In a module folder they could not be
  edited by the person who needed to edit them, and an update replaced them.
- Update-MarkstrataPageSetting -UpdateConfig records the web part settings in the
  per-user config override instead of rewriting the module's shipped config.
- The module folder is only ever read.

1.0.0
- First public release.
- One renderer page serves the whole library through a strataDoc query string.
- Category indexes named after their folder; home index grouped by theme.
- Navigation built from the document library, with non-clickable group headings.
- First-run bootstrap creates the Entra ID app registration and grants it access
  to the target site only (Sites.Selected).
'@

        } # End of PSData hashtable

    } # End of PrivateData hashtable

}
