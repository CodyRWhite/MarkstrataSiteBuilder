function Get-MarkstrataMediaUsage {
    <#
    .SYNOPSIS
        Work out which attachments the Markdown actually references, and which are orphans.

    .DESCRIPTION
        Scans every .md in the local library for image references and compares them against the
        files held in an attachment library. One scan answers both questions the attachment tools
        need: what is in use (so it can be relocated) and what is not (so it can be retired).

        Matching is on FILE NAME, not full URL, because the URL base is exactly what the relocation
        changes - matching on the whole URL would report every attachment as an orphan the moment
        the base moved.

        Reference extraction deliberately allows BALANCED parentheses inside the destination:
        "Picture_1_(Small).jpg" is a legal CommonMark link, and a naive [^)]+ pattern truncates it
        and then reports the file as both a broken link and an orphan.

    .PARAMETER LibraryRoot
        Local root of the synced document library. Defaults to markdown.libraryRoot.

    .PARAMETER AttachmentLibrary
        List title of the library holding the attachments. Defaults to markdown.legacyMediaLibrary, which is empty unless you are migrating out of an older image library - so normally this is passed explicitly.

    .OUTPUTS
        PSCustomObject with InUse and Orphaned (each: Name, Size, ServerRelativeUrl), Missing
        (referenced but absent), and Documents (documents that reference at least one image).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [string]$LibraryRoot,

        [string]$AttachmentLibrary
    )

    $config = Get-MarkstrataConfig
    if ([string]::IsNullOrWhiteSpace($LibraryRoot)) { $LibraryRoot = [string]$config.Markdown.libraryRoot }
    if ([string]::IsNullOrWhiteSpace($AttachmentLibrary)) {
        $AttachmentLibrary = [string](Get-OptionalProperty $config.Markdown "legacyMediaLibrary" "")
    }
    if ([string]::IsNullOrWhiteSpace($AttachmentLibrary)) {
        throw "No media library given. Pass -AttachmentLibrary, or set markdown.legacyMediaLibrary."
    }
    if (-not (Test-Path -LiteralPath $LibraryRoot)) { throw "Markdown library root not found: $LibraryRoot" }

    # Balanced-paren aware: destination is a run of non-paren/whitespace characters, optionally
    # containing balanced (...) groups.
    $imagePattern = '!\[[^\]]*\]\((?<url>(?:[^()\s]|\([^()]*\))+)'

    $referenced = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $documents = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($file in (Get-ChildItem -LiteralPath $LibraryRoot -Recurse -File -Filter "*.md")) {
        $text = Get-Content -LiteralPath $file.FullName -Raw
        if ([string]::IsNullOrEmpty($text)) { continue }
        foreach ($match in [regex]::Matches($text, $imagePattern)) {
            $url = $match.Groups["url"].Value
            if ($url -match '^(?:https?:)?//') { continue }          # external image, not ours
            $name = [uri]::UnescapeDataString([System.IO.Path]::GetFileName($url))
            if ([string]::IsNullOrWhiteSpace($name)) { continue }
            if ($name -match '^<.*>$') { continue }                   # a placeholder in a how-to
            [void]$referenced.Add($name)
            [void]$documents.Add($file.FullName)
        }
    }

    $inUse = [System.Collections.Generic.List[object]]::new()
    $orphaned = [System.Collections.Generic.List[object]]::new()
    $present = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)

    foreach ($item in (Get-PnPListItem -List $AttachmentLibrary -PageSize 1000)) {
        if ([int]$item.FieldValues.FSObjType -eq 1) { continue }      # folder
        $name = [string]$item.FieldValues.FileLeafRef
        [void]$present.Add($name)
        $record = [pscustomobject]@{
            Id                = $item.Id
            Name              = $name
            Size              = [long]$item.FieldValues.File_x0020_Size
            ServerRelativeUrl = [string]$item.FieldValues.FileRef
        }
        if ($referenced.Contains($name)) { $inUse.Add($record) } else { $orphaned.Add($record) }
    }

    $missing = @($referenced | Where-Object { -not $present.Contains($_) } | Sort-Object)

    return [pscustomobject]@{
        InUse     = $inUse
        Orphaned  = $orphaned
        Missing   = $missing
        Documents = @($documents)
        Library   = $AttachmentLibrary
    }
}
