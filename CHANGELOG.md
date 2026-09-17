# Changelog

All notable changes to this project are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
