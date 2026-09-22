# MarkstrataSiteBuilder

Publish a folder of Markdown files as a browsable SharePoint Online site.

You keep writing Markdown. SharePoint gets a real site around it: a navigation menu, category
landing pages, a home page, and working links between documents. Nothing is copied or converted
on the way in, so editing a file is all it takes to change what the site shows.

```powershell
Import-Module .\MarkstrataSiteBuilder.psd1
Initialize-MarkstrataConfig          # asks for the site and the folder
Connect-MarkstrataSite               # offers to create the app registration it signs in with
New-MarkstrataRenderer -SetHomePage  # the one page that renders every document
New-MarkstrataIndex                  # category and home indexes
Update-MarkstrataNavigation          # the menu
```

---

## What it builds

**One page, not one page per document.** The renderer page (`Wiki.aspx`) holds a single Markdown
web part and takes the document to show from its query string:

```
https://contoso.sharepoint.com/sites/docs/Wiki.aspx?strataDoc=Alpha/Page One.md
```

A library of 500 documents is still one page. Adding a document does not mean creating a page,
and deleting one does not leave a dead page behind.

**A menu from the folder structure.** Top-level folders are categories. Categories are gathered
into a handful of named groups so the header bar stays readable - a SharePoint menu shows about
five or six entries before hiding the rest behind a `...` nobody clicks. Group headings are
labels, not links: a group heading is not a document and should not pretend to be a page.

**Generated index screens.** Each category gets an index named after its own folder
(`Alpha/Alpha.md`), listing its documents and its subfolders as sections. The home
index lists every category, grouped the same way as the menu. They carry no document counts,
because a count written onto a generated page is wrong the moment someone adds a document
without re-running.

**Links that survive.** Internal links can be written as wiki links (`[[Alpha/Page One]]`)
which address the *document* rather than a page URL, so they keep working when pages change.
`Convert-MarkstrataLink` converts an existing library in either direction.

---

## Requirements

| | |
| --- | --- |
| PowerShell | 7.2 or later |
| [PnP.PowerShell](https://pnp.github.io/powershell/) | 3.0 or later |
| Markstrata web part | installed in your tenant app catalogue and available on the target site |
| SharePoint | an existing site, and a document library holding the `.md` files |
| Entra ID | an account that may create app registrations, for the one-time setup |

The **Markstrata** SharePoint Framework web part does the actual Markdown rendering. This module
builds and maintains the site around it.

---

## Setting it up

### 1. Point it at your site

```powershell
Initialize-MarkstrataConfig
```

It asks for the site URL, the local folder holding your Markdown, and what the home page should
be called. Everything else has a working default. Settings are written to
`%LOCALAPPDATA%\MarkstrataSiteBuilder\config.json`, never to the module folder, so updating the
module does not take your configuration with it - and an installed module, which normally sits
somewhere you cannot write to, never needs to be written to at all.

The local folder is normally a **synced** copy of the SharePoint library (Documents → Sync in the
browser). That is the whole authoring model: edit a file in your editor, save, and OneDrive
carries it up.

For a scripted setup:

```powershell
Initialize-MarkstrataConfig `
    -SiteUrl https://contoso.sharepoint.com/sites/docs `
    -LibraryRoot "{UserProfile}\Contoso\Docs - Documents" `
    -HomeTitle "Documentation"
```

### 2. Connect

```powershell
Connect-MarkstrataSite
```

On a first run there is nothing to sign in with, and it says so and offers to fix it. Answering
yes creates an Entra ID app registration through the normal consent prompts in your browser and
saves its client ID. Nothing has to be assembled by hand in the portal.

To do it explicitly, or to hand it to an administrator:

```powershell
Register-MarkstrataApp            # delegated sign-in app
```

### 3. Check

```powershell
Test-MarkstrataAccess
```

Read-only. It reports the connection, write access, both libraries, the local folder and whether
the web part named by `markdownPage.componentId` is actually available on the site - the last one
being the difference between a working page and a blank canvas. Run it before a first publish: a
page built without its component renders blank while the build reports success.

#### Which web part

The Markstrata package installs more than one component - `Markstrata - Markdown` and
`Markstrata - HTML`. `markdownPage.componentId` picks the one every page is built with, by GUID,
because display names have already changed once and a bare `Markstrata` now matches neither.

Building with the other component is the same operation: put its id in `componentId` and set
`webPartProperties` to the keys that component accepts. Nothing else differs. To list what a site
has:

```powershell
Get-PnPAvailablePageComponents -Page Wiki.aspx |
    Where-Object Name -like "*Markstrata*" | Select-Object Name, Id
```

`componentName` is a fallback used only when the id matches nothing, and a build that falls back
says so. A name matching two components is an error rather than a guess.

### 4. Build

```powershell
New-MarkstrataRenderer -SetHomePage    # the single renderer page
New-MarkstrataIndex                    # category and home indexes
Update-MarkstrataNavigation            # the menu
```

`Invoke-MarkstrataRefresh` is **not** this sequence. It regenerates the indexes, waits for
OneDrive, then runs `Publish-MarkstrataLibrary -RemoveOrphan` - a page per document - and rebuilds
the menu. It never touches the renderer. On a site using the single-renderer model that rebuilds
the page-per-document tree the renderer exists to replace, so reach for it only if you actually
want those pages.

---

## Day to day

**Editing a document needs nothing.** The page renders the file rather than holding a copy of it,
so a saved edit is live as soon as it syncs.

**Adding, moving, renaming or deleting one** changes the indexes and the menu, so re-run:

```powershell
New-MarkstrataIndex
Update-MarkstrataNavigation
```

The renderer page itself needs nothing: it already serves whatever documents exist.

### Organising the menu

Two optional files in `%LOCALAPPDATA%\MarkstrataSiteBuilder`, created there from the module's
templates by `Initialize-MarkstrataConfig` (or the first time anything reads them):

| File | What it does | If you leave it empty |
| --- | --- | --- |
| `categories.json` | Display name and order for each top-level folder | Folders use their own names, sorted A-Z |
| `category-groups.json` | Which group each category sits under in the menu | Every category lands in the default group |

`categories.json` exists mainly for punctuation: SharePoint will not take `&` in a path, so a
category folder has to be called `Gamma and Delta` while the menu should read `Gamma & Delta`.

`Initialize-MarkstrataConfig -Show` prints both paths. To keep either file somewhere else - a
network folder a team shares, or a repository - put a full path in `categories.listFile` or
`navigation.groupFile`.

### Images

Put them in `_media` inside the same library, next to the documents. The leading underscore keeps
the folder out of the indexes and the publisher. Migrating images out of an older library:

```powershell
Move-MarkstrataMedia -AttachmentLibrary "Site Assets"              # relocate and rewrite the links
Remove-MarkstrataOrphanMedia -AttachmentLibrary "Site Assets" -WhatIf   # then drop -WhatIf to sweep
```

---

## Unattended runs

For a scheduled refresh with nobody signed in, add an app-only registration with a certificate:

```powershell
Connect-MarkstrataSite                 # as an administrator who owns the site
Register-MarkstrataApp -Unattended
```

It creates the app and a self-signed certificate, grants it `Sites.Selected` and then access to
**the target site and nothing else**, and records the client ID and thumbprint. The private key
stays in `CurrentUser\My` and is never written to config.

This is deliberately not `Sites.FullControl.All`. A documentation publisher has no business being
able to read and rewrite every site in the tenant, and a leaked certificate should reach exactly
one site.

Afterwards:

```powershell
Connect-MarkstrataSite -Force          # now app-only
New-MarkstrataIndex                    # what a scheduled run actually needs
Update-MarkstrataNavigation
```

---

## Commands

| Command | |
| --- | --- |
| `Initialize-MarkstrataConfig` | Set up, change or show your configuration |
| `Register-MarkstrataApp` | Create the app registration (delegated, or `-Unattended`) |
| `Connect-MarkstrataSite` | Connect, bootstrapping the app registration if needed |
| `Disconnect-MarkstrataSite` | Close the connection |
| `Test-MarkstrataAccess` | Read-only check of everything the builder needs |
| `New-MarkstrataRenderer` | Create the single renderer page |
| `New-MarkstrataIndex` | Generate the category and home indexes |
| `Publish-MarkstrataLibrary` | Create a page per document (only if you want them) |
| `Update-MarkstrataNavigation` | Rebuild the menu (contents only; `-MegaMenu`/`-CascadingMenu` set the style) |
| `Invoke-MarkstrataRefresh` | Indexes, then a page per document, then the menu (not the renderer) |
| `New-MarkstrataPage` | Create one page for one document |
| `Update-MarkstrataPageSetting` | Push web part settings to existing pages |
| `Convert-MarkstrataLink` | Convert between wiki links and page links |
| `Move-MarkstrataMedia` | Relocate images into the library and rewrite links |
| `Remove-MarkstrataOrphanMedia` | Find and recycle unreferenced images |
| `Remove-MarkstrataLegacyPage` | Retire pages the renderer has replaced |

Every command has full help: `Get-Help Publish-MarkstrataLibrary -Full`.

---

## Notes on behaviour worth knowing

- **Deletions recycle.** Pages and files go to the site recycle bin, recoverable for 93 days.
  Every destructive command supports `-WhatIf`.
- **Three characters in a document name are always escaped in a URL**, whatever the encoding
  setting: `&` splits the query string, `#` is taken as the page fragment, and `+` decodes to a
  space. The first two fail silently, which is why they are not left to the encoding mode.
- **A document must not share its category folder's name** - it would collide with the generated
  index for that category.
- **Group headings are not clickable** and have no page of their own.
- **A navigation rebuild never changes the menu style.** Mega menu versus cascading is a deliberate
  choice made in the SharePoint UI, and `Update-MarkstrataNavigation` rebuilds the menu's CONTENTS
  only. Change the style on purpose with `-MegaMenu` or `-CascadingMenu`; the summary's `MenuStyle`
  says what the run did (`Unchanged`, `MegaMenu`, `CascadingMenu` or `Failed`).

  This is a **behaviour change**: until 1.3.0 the command forced the style to mega menu on every
  run, because `navigation.megaMenu` defaulted to true and there was no way to opt out. A rebuild
  run to update links would silently revert a site an administrator had switched to cascading. The
  setting has been removed; a leftover `megaMenu` key in your own config is ignored, with a warning.
- **Nothing is ever written to the module folder.** Your configuration, the category list and the
  menu groups all live in `%LOCALAPPDATA%\MarkstrataSiteBuilder`; the `config/` folder inside the
  module holds the shipped defaults and the templates those files are seeded from, and is only
  ever read. That is what makes an installation under `Program Files`, or any module folder you
  have no write access to, work the same as a repository checkout - and what keeps a module update
  from taking your settings with it.
- **Every run writes a log.** One file per run, never overwritten, in
  `%APPDATA%\MarkstrataSiteBuilder\logs`, named
  `MarkstrataSiteBuilder_<yyyyMMdd_HHmmss>_<pid>.log`. It opens in CMTrace or OneTrace with
  severity colouring, and reads fine in any text editor. Old logs are pruned to 30 files and 30
  days, whichever is stricter, so the folder does not need managing. The first lines of each file
  name the run: user, machine, module version, PowerShell version.

---

## Development

```powershell
Invoke-ScriptAnalyzer -Path . -Recurse -Settings .\PSScriptAnalyzerSettings.psd1
Invoke-Pester -Path .\tests
```

The tests are offline. They run against a configuration injected into module scope, not against
the shipped config or your own, so a passing suite says something about the code rather than
about the tenant it was run in.

Imported from a checkout, the module still reads `categories.json` and `category-groups.json` from
`%LOCALAPPDATA%\MarkstrataSiteBuilder` - `config/` holds the templates they are seeded from, not
the live files. To work on them in place, point `categories.listFile` and `navigation.groupFile` at
full paths inside the checkout.

## Licence

MIT. See [LICENSE](LICENSE).
