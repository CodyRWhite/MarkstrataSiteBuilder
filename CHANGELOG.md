# Changelog

All notable changes to this project are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
