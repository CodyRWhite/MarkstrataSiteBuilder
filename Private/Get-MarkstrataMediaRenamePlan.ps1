function Get-MarkstrataMediaRenamePlan {
    <#
    .SYNOPSIS
        Work out a descriptive file name for every image reference, from its alt text and the
        document it appears in.

    .DESCRIPTION
        Migrated attachments carry the names MediaWiki gave them - Picture_1_(Small).jpg,
        IMG_0042.PNG, Screenshot3.PNG - which are unnavigable once they are all in one folder.
        Every reference in the library does, however, carry real alt text, so a far better name can
        be derived: "<document>-<description>.<ext>".

        The document prefix does the organising: sorting the media folder puts every image next to
        its siblings, and the name says what it is and where it belongs without opening it.

        One target per (document, source file) pair, so an image used by several documents is
        duplicated under each document's own name and each document stays self-contained. An image
        referenced twice *within* one document still resolves to a single file.

        Names are lowercase, hyphen-separated, and capped so the resulting library path stays well
        inside SharePoint's limit. A collision gets a numeric suffix, though the document prefix
        makes that rare.

    .PARAMETER LibraryRoot
        Local root of the synced document library. Defaults to markdown.libraryRoot.

    .OUTPUTS
        PSCustomObject per (document, source file): DocumentPath, DocumentName, SourceFile, Alt,
        TargetName.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [string]$LibraryRoot
    )

    $config = Get-MarkstrataConfig
    if ([string]::IsNullOrWhiteSpace($LibraryRoot)) { $LibraryRoot = [string]$config.Markdown.libraryRoot }
    if (-not (Test-Path -LiteralPath $LibraryRoot)) { throw "Markdown library root not found: $LibraryRoot" }

    # Balanced-paren aware, so "Picture_1_(Small).jpg" is read whole.
    $imagePattern = '!\[(?<alt>[^\]]*)\]\((?<url>(?:[^()\s]|\([^()]*\))+)\)'

    $toSlug = {
        param([string]$Value)
        $slug = ($Value -replace '[^A-Za-z0-9]+', '-').Trim('-').ToLowerInvariant()
        return ($slug -replace '-{2,}', '-')
    }

    $plan = [System.Collections.Generic.List[object]]::new()
    $seenPair = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $takenNames = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)

    foreach ($file in (Get-ChildItem -LiteralPath $LibraryRoot -Recurse -File -Filter "*.md" | Sort-Object FullName)) {
        $text = Get-Content -LiteralPath $file.FullName -Raw
        if ([string]::IsNullOrEmpty($text)) { continue }

        $documentName = [System.IO.Path]::GetFileNameWithoutExtension($file.Name)
        $documentSlug = & $toSlug $documentName

        foreach ($match in [regex]::Matches($text, $imagePattern)) {
            $url = $match.Groups["url"].Value
            if ($url -match '^(?:https?:)?//') { continue }
            $sourceFile = [uri]::UnescapeDataString([System.IO.Path]::GetFileName($url))
            if ([string]::IsNullOrWhiteSpace($sourceFile) -or $sourceFile -match '^<.*>$') { continue }

            # One target per (document, source file): a second reference in the same document
            # points at the same file rather than making a duplicate.
            $pairKey = "$($file.FullName)|$sourceFile"
            if (-not $seenPair.Add($pairKey)) { continue }

            $extension = [System.IO.Path]::GetExtension($sourceFile).ToLowerInvariant()
            $alt = $match.Groups["alt"].Value.Trim()
            $altSlug = & $toSlug $alt
            if ([string]::IsNullOrWhiteSpace($altSlug)) {
                # No usable alt text - fall back to the original name so something survives.
                $altSlug = & $toSlug ([System.IO.Path]::GetFileNameWithoutExtension($sourceFile))
            }

            # Cap the leaf; trim the description rather than the document prefix, which is what
            # makes the folder sort usefully.
            $maxLeaf = 110 - $extension.Length
            $candidate = "$documentSlug-$altSlug"
            if ($candidate.Length -gt $maxLeaf) { $candidate = $candidate.Substring(0, $maxLeaf).Trim('-') }

            $targetName = "$candidate$extension"
            $suffix = 2
            while (-not $takenNames.Add($targetName)) {
                $targetName = "$candidate-$suffix$extension"
                $suffix++
            }

            $plan.Add([pscustomobject]@{
                DocumentPath = $file.FullName
                DocumentName = $documentName
                SourceFile   = $sourceFile
                Alt          = $alt
                TargetName   = $targetName
            })
        }
    }

    return $plan
}
