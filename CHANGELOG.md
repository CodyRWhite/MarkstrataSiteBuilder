# Changelog

All notable changes to this project are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.5.0] - 2026-09-22

### Added
- **`markdown.documentExtensions`, so a library can hold `.html` documents.** The two installed
  components read different files - the Markdown web part loads `.md`, the HTML one `.html` and
  `.htm` - and this module tested for `"*.md"` in four separate places, so an HTML library published
  nothing at all. The publish walk, the navigation walk, the refresh sync comparison and the
  readiness check now all follow the configured set.

  It is a fact about the library rather than something inferred from `componentId`: a library is a
  folder of files, and what is in it is a property of the folder.
- **An "Index naming" readiness check.** `markdownIndex.indexFileName` and `homeFileName` have to end
  in one of `documentExtensions`, or the generated indexes are published and then not recognised as
  indexes - so they are titled and ordered as ordinary documents and the category headings go
  missing. Silent, and awkward to diagnose after the fact.

### Notes
- `Convert-MarkstrataLink` and the media commands remain Markdown-only, deliberately: wiki links and
  Markdown image syntax are features of Markdown rather than of the library.
- Generated index screens are still written as Markdown whatever the library holds. An HTML library
  publishes and gets a menu, but its indexes are not yet emitted as HTML.

## [1.4.0] - 2026-09-22

### Changed
- **`Invoke-MarkstrataRefresh` now builds the renderer instead of a page per document.** The
  sequence is indexes, wait for OneDrive, `New-MarkstrataRenderer`, `Update-MarkstrataNavigation` -
  what the command's name implies and what the README quick start recommends. It previously ran
  `Publish-MarkstrataLibrary -RemoveOrphan`, which on a site using the single renderer rebuilt the
  very page-per-document tree the renderer exists to replace. `Publish-MarkstrataLibrary` is
  unchanged for anyone who wants those pages, and `-OrphanOnly` still sweeps them.
- **It no longer changes the site's welcome page on every run.** The old step 4 passed
  `-SetHomePage` unconditionally, pointing the welcome page at the generated home index. Which page
  a site lands on is a deliberate choice, and a routine refresh reimposing it is the same class of
  bug as the menu style forced in 1.3.0. Pass `-SetHomePage` to set it, deliberately, and it now
  points at the renderer.

### Removed
- `Invoke-MarkstrataRefresh -KeepOrphan`, which only meant something for the page-per-document pass
  that is gone. Scripts passing it will need it removed.

### Added
- `Invoke-MarkstrataRefresh -SkipRenderer`, for the common case where documents have only come and
  gone and the renderer - which serves whatever exists - needs nothing done to it.

## [1.3.0] - 2026-09-22

### Added
- **`-ComponentId` on the build commands and on `Test-MarkstrataAccess`.** The package installs more
  than one component, and until now choosing between them meant editing config between runs.
  `New-MarkstrataRenderer`, `New-MarkstrataPage` and `Publish-MarkstrataLibrary` take an id for a
  single run, so one library can keep some documents on each. `Test-MarkstrataAccess -ComponentId`
  confirms a component is available on the site before anything is built with it.

  An id passed explicitly never falls back to `componentName`: asking for one component and silently
  getting another would build pages that look fine and render with the wrong web part.

- **The HTML component's id and property defaults are recorded in the shipped config**, under the
  documentation keys `_htmlComponentId` and `_htmlWebPartProperties`, read from the web part's own
  manifest rather than guessed. The loader ignores `_`-prefixed keys, so they are reference data and
  cannot change a build. Switching components is now a copy rather than a lookup.

  Noted with them, because it is the thing that decides whether switching is useful: the HTML
  component loads `.html` and `.htm` documents, and this module's library walk finds only `.md`.
  Attaching either component works identically; publishing a whole library with the HTML one does
  not yet, and the README says so.

### Changed
- **`navigation.megaMenu` has been removed** and is no longer read. A key left in your own config is
  ignored and warns, pointing at the switches. This is a behaviour change for anyone who has been
  running `Update-MarkstrataNavigation`: the menu style was being set for them on every run, and now
  it is not.
- The navigation summary gained `MenuStyle`, reporting what the run did to the style - `Unchanged`,
  `MegaMenu`, `CascadingMenu` or `Failed`. Not being able to tell from the output was half of what
  made the original behaviour so hard to spot.
- A failed style change now warns with the reason instead of being swallowed by
  `-ErrorAction SilentlyContinue`. It still does not fail the rebuild.

- The Markstrata web part is described as this project's companion rather than a third party's. It
  is the same author's, released separately because a web part deploys to a tenant app catalogue and
  a PowerShell module does not, and the README, module header and manifest now link to it.
### Fixed
- **A navigation rebuild forced the site's menu style to mega menu on every run.**
  `navigation.megaMenu` defaulted to true and there was no switch to opt out, so
  `Update-MarkstrataNavigation` - run to update menu LINKS - silently reverted any site an
  administrator had deliberately switched to a cascading menu in the SharePoint UI. Nobody connected
  the two, because the call used `-ErrorAction SilentlyContinue` and the command's output said
  nothing about the style at all.

  Rebuilding a menu's contents must never change its style. The style is now changed only when
  asked for, by the new `-MegaMenu` and `-CascadingMenu` switches (mutually exclusive). With
  neither, the current value is read, logged and left alone.
- The session's resolved-component cache answered "something was resolved once" rather than
  remembering WHAT was resolved. Two runs in one session asking for different components would have
  received the first one's - silently, since either attaches perfectly well. The cache is now keyed
  on what was asked for.


## [1.2.0] - 2026-09-22

### Fixed
- **Pages published blank while reporting success.** The web part was attached by DISPLAY NAME
  (`markdownPage.componentName`, defaulting to "Markstrata"), and the package now installs
  "Markstrata - Markdown" and "Markstrata - HTML", so the name matched nothing.
  `Add-PnPPageWebPart -Component` does not throw when it matches nothing: it attaches a control
  with an empty `WebPartId`, SharePoint has no component to instantiate, and the page renders blank
  while the command reports "Created". A production run published 121 blank pages that way.

  The component is now resolved to an OBJECT through `Get-PnPAvailablePageComponents`, by
  `componentId` and falling back to `componentName`, and every page is asserted afterwards to carry
  it. A bare GUID string passed to `-Component` fails in the same silent way, which is why the id is
  looked up rather than handed over. `Publish-MarkstrataLibrary` resolves once before building
  anything, so an unresolvable component stops the run instead of failing per page.
- **A partial user override discarded the nested keys beside it.** Writing
  `"markdownPage": { "webPartProperties": { "allowHtml": true } }` into the user config replaced the
  whole object, taking `colorMode`, `tocPosition`, `enableMermaid` and the other thirty-odd keys
  with it. Every page built afterwards carried web part defaults nobody chose. Nested objects are
  now merged key by key; arrays and scalars still replace outright.
- **The orphan sweep recycled the renderer page.** No Markdown document backs `Wiki.aspx` - that is
  the point of it - so `Publish-MarkstrataLibrary -RemoveOrphan` read the one page the whole site
  depends on as an orphan and deleted it. The renderer and the site's current welcome page are now
  spared, as they already were by `Remove-MarkstrataLegacyPage`. The sweep is also skipped entirely
  when `markdownPage.pageRootFolder` is empty, where every page in the library - including ones
  built by hand - would otherwise qualify.
- **`Test-MarkstrataAccess` called a cmdlet that no longer exists.**
  `Get-PnPAvailableClientSideComponent` is gone from PnP.PowerShell, so the web part check warned on
  every run and told nobody anything. It now resolves the configured `componentId` against the site
  with `Get-PnPAvailablePageComponents` and FAILS when it is absent, naming the components that are
  installed and their ids. This is the check that would have caught the blank pages before any were
  built.
- **`Convert-MarkstrataLink` rewrote links inside code blocks.** A page documenting the link syntax
  had its examples converted whenever the example target happened to resolve. Fenced blocks and
  inline code spans are now left alone in both directions.

### Changed
- `markdownPage.componentId` is documented as what SELECTS the web part, now that the package ships
  more than one component. Building with the HTML component instead is the same operation: put its
  id in `componentId` and set `webPartProperties` to the keys it accepts. `componentName` is a
  documented fallback, reported when it is used, and an error when it matches more than one
  component. Its default is now "Markstrata - Markdown".
- The README described `Invoke-MarkstrataRefresh` as rebuilding "renderer, indexes, and menu". It
  runs `Publish-MarkstrataLibrary -RemoveOrphan` - a page per document - and never touches the
  renderer, which on a single-renderer site rebuilds the page-per-document tree the renderer exists
  to replace. The README now says what the code does, and the quick start and the unattended example
  use the renderer path.

## [1.1.0] - 2026-09-17

### Changed
- **The editable JSON files live under the user's profile.** `categories.json` and
  `category-groups.json` are now read from `%LOCALAPPDATA%\MarkstrataSiteBuilder`, and are created
  there from the module's templates the first time they are needed. Installed into a module folder
  (`Program Files` for a machine-wide install), the copies in `config/` were unwritable for the
  person editing them and were replaced by the next module update, which made them useless to edit.
  A file already in the data folder is left exactly as it is, and a developer's edits in a
  repository checkout are carried across the first time an installed copy runs.
- `categories.listFile` and `navigation.groupFile` accept a full path, so either file can be kept
  in a shared folder instead.
- `Initialize-MarkstrataConfig` creates both files and reports them, alongside the config override,
  as `DataFolder`, `CategoryFile` and `CategoryGroupFile`. `-Show` reports the same paths and, as
  before, creates nothing.
- The module folder is now only ever READ. `config/` holds the shipped defaults and the templates,
  nothing else.

### Fixed
- `Update-MarkstrataPageSetting -UpdateConfig` rewrote the shipped
  `config/MarkstrataSiteBuilder.config.json` inside the module folder, which fails outright on an
  installed module and was discarded on update where it did not. It now records the web part
  settings in the per-user override, where every other setting already goes.
- `%LOCALAPPDATA%` and `%APPDATA%` are Windows-only; with neither set, every path built from them
  threw. PowerShell on Linux and macOS now falls back to `$XDG_DATA_HOME`, then `~/.local/share`.

## [1.0.0] - 2026-09-16

First public release.

### Added
- **Single renderer page.** One page serves every document in the library through a `strataDoc`
  query string, so a library of any size needs one page rather than one per document.
- **Generated indexes.** A category index named after its own folder, plus a home index grouped
  by theme. Both recurse into subfolders and carry no derived counts.
- **Navigation from the library.** The menu is built from the documents that exist rather than
  from the pages that happen to exist. Group headings are labels rather than links.
- **First-run bootstrap.** `Connect-MarkstrataSite` detects that there is no app registration to
  sign in with and offers to create one through Entra's own consent prompts.
  `Register-MarkstrataApp -Unattended` adds an app-only certificate app granted access to the
  target site only, via `Sites.Selected`.
- **Configuration wizard.** `Initialize-MarkstrataConfig` writes to a per-user override, so the
  shipped defaults are never edited and an update cannot overwrite a user's settings.
- **Link conversion.** `Convert-MarkstrataLink` converts a whole library between wiki links and
  page links, in either direction, preserving fragments.
- **Media commands.** `Move-MarkstrataMedia` relocates images into the library and renames them
  from the context they appear in; `Remove-MarkstrataOrphanMedia` sweeps unreferenced files and
  the empty folders left behind.
- **Readiness check.** `Test-MarkstrataAccess` verifies the connection, write access, both
  libraries, the local folder and whether the Markstrata web part is available on the site.

### Notes
- `%`, `&`, `#` and `+` are escaped in a `strataDoc` value in every encoding mode. `&` splits the
  query string and `#` is taken as the page fragment; both fail silently.
- `Add-PnPNavigationNode` truncates a URL at the path, dropping query string and fragment. Nodes
  are re-set through the node object after creation.
