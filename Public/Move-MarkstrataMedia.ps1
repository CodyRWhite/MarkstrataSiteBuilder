function Move-MarkstrataMedia {
    <#
    .SYNOPSIS
        Relocate in-use attachments into the synced document library under descriptive names, and
        repoint the Markdown at them.

    .DESCRIPTION
        Images often start life in a library of their own, which is NOT synced to
        the desktop. The authoring model is "edit the .md locally and it syncs", so adding an image
        meant uploading through the browser into a different library and hand-writing the URL -
        enough friction that people simply stop adding images.

        Moving them into a folder of the synced library (Shared Documents\_media by default) means
        an image is dropped in next to the document that uses it.

        The copy is SERVER-SIDE (Copy-PnPFile): the bytes never travel to this machine and back, so
        there is no upload to wait for. OneDrive brings the new folder down afterwards. Markdown
        references are then rewritten in place, matching the old base URL whether its spaces are
        literal or percent-encoded.

        Files are RENAMED as they are copied, from the MediaWiki originals (Picture_1_(Small).jpg,
        Screenshot3.PNG) to "<document>-<description>.<ext>" built from each reference's alt text -
        see Get-MarkstrataMediaRenamePlan. An image used by several documents is copied once per
        document so each stays self-contained.

        Rewriting the .md is all that is needed - pages reference the document, not its content, so
        the new image URLs are live immediately with no page rebuild.

        Only referenced attachments are moved. Use Remove-MarkstrataOrphanMedia for the rest.

    .PARAMETER LibraryRoot
        Local root of the synced document library. Defaults to markdown.libraryRoot.

    .PARAMETER MediaFolder
        Folder inside the document library to hold the attachments. Defaults to markdown.mediaFolder.

    .PARAMETER AttachmentLibrary
        Library currently holding the attachments. Defaults to markdown.legacyMediaLibrary, which is empty unless you are migrating out of an older image library - so normally this is passed explicitly.

    .PARAMETER IncludeOrphan
        Also move attachments nothing references. Off by default - orphans should be retired, not
        carried across.

    .PARAMETER SkipRewrite
        Copy the files but leave the Markdown references pointing at the old location.

    .PARAMETER PassThru
        Emit one object per attachment instead of only the summary.

    .OUTPUTS
        PSCustomObject summary (Copied, Skipped, Failed, DocumentsRewritten, TargetFolder).

    .EXAMPLE
        Move-MarkstrataMedia -WhatIf

        Show which attachments would move and which documents would be rewritten.

    .EXAMPLE
        Move-MarkstrataMedia

        Copy every referenced attachment into Shared Documents\_media and repoint the Markdown.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [string]$LibraryRoot,

        [string]$MediaFolder,

        [string]$AttachmentLibrary,

        [switch]$IncludeOrphan,

        [switch]$SkipRewrite,

        [switch]$PassThru
    )

    if (-not $script:SharePointReady) {
        throw "Not connected. Run Connect-MarkstrataSite first."
    }

    $config = Get-MarkstrataConfig
    if ([string]::IsNullOrWhiteSpace($LibraryRoot))       { $LibraryRoot = [string]$config.Markdown.libraryRoot }
    if ([string]::IsNullOrWhiteSpace($MediaFolder))       { $MediaFolder = [string]$config.Markdown.mediaFolder }
    if ([string]::IsNullOrWhiteSpace($AttachmentLibrary)) {
        $AttachmentLibrary = [string](Get-OptionalProperty $config.Markdown "legacyMediaLibrary" "")
    }
    if ([string]::IsNullOrWhiteSpace($AttachmentLibrary)) {
        throw "No media library given. Pass -AttachmentLibrary, or set markdown.legacyMediaLibrary."
    }

    $usage = Get-MarkstrataMediaUsage -LibraryRoot $LibraryRoot -AttachmentLibrary $AttachmentLibrary
    $sourceByName = @{}
    foreach ($attachment in @($usage.InUse) + @($usage.Orphaned)) { $sourceByName[$attachment.Name] = $attachment }

    # Each reference gets a descriptive "<document>-<description>.<ext>" name instead of the
    # MediaWiki original (Picture_1_(Small).jpg), which is unnavigable once everything is one folder.
    $plan = @(Get-MarkstrataMediaRenamePlan -LibraryRoot $LibraryRoot | Where-Object { $sourceByName.ContainsKey($_.SourceFile) })

    $toMove = @($plan)
    if ($IncludeOrphan) {
        foreach ($attachment in $usage.Orphaned) {
            $toMove += [pscustomobject]@{
                DocumentPath = ""; DocumentName = ""; SourceFile = $attachment.Name
                Alt = ""; TargetName = $attachment.Name
            }
        }
    }

    $libraryUrl = ([string]$config.Markdown.libraryServerRelativeUrl).TrimEnd("/")
    $targetFolderUrl = "$libraryUrl/$MediaFolder"

    Write-MarkstrataLog -Message "Attachments: $($usage.InUse.Count) in use, $($usage.Orphaned.Count) orphaned; $($toMove.Count) copy target(s) to $targetFolderUrl." -Component "Attachment"
    if ($usage.Missing.Count -gt 0) {
        Write-MarkstrataLog -Message "Referenced but absent from '$AttachmentLibrary': $($usage.Missing -join ', ')" -Level Warning -Component "Attachment"
    }

    # Ensure the destination folder exists (idempotent). Resolve-PnPFolder is the obvious call and
    # throws "the property or field 'ServerRelativeUrl' has not been initialized" against a library
    # path, so probe and create explicitly instead.
    $siteRoot = Get-MarkstrataSiteRelativeRoot
    $librarySiteRelative = $libraryUrl
    if ($siteRoot -and $librarySiteRelative.StartsWith($siteRoot, [StringComparison]::OrdinalIgnoreCase)) {
        $librarySiteRelative = $librarySiteRelative.Substring($siteRoot.Length)
    }
    $librarySiteRelative = $librarySiteRelative.Trim("/")
    $mediaSiteRelative = "$librarySiteRelative/$MediaFolder"

    if ($toMove.Count -gt 0 -and $PSCmdlet.ShouldProcess($targetFolderUrl, "Create media folder")) {
        $existingFolder = $null
        try { $existingFolder = Get-PnPFolder -Url $mediaSiteRelative -ErrorAction Stop } catch { $existingFolder = $null }
        if (-not $existingFolder) {
            try {
                Add-PnPFolder -Name $MediaFolder -Folder $librarySiteRelative -ErrorAction Stop | Out-Null
                Write-MarkstrataLog -Message "Created media folder $targetFolderUrl." -Component "Attachment"
            } catch {
                Write-MarkstrataLog -Message "Could not create '$targetFolderUrl': $($_.Exception.Message)" -Level Error -Component "Attachment"
                throw
            }
        }
    }

    $results = [System.Collections.Generic.List[object]]::new()
    $copied = 0; $skipped = 0; $failed = 0; $index = 0

    foreach ($entry in $toMove) {
        $index++
        $source = $sourceByName[$entry.SourceFile]
        $target = "$targetFolderUrl/$($entry.TargetName)"
        if (-not $PSCmdlet.ShouldProcess($target, "Copy attachment as")) {
            $results.Add([pscustomobject]@{ SourceFile = $entry.SourceFile; TargetName = $entry.TargetName; Document = $entry.DocumentName; Status = "WhatIf" })
            continue
        }
        try {
            # Server-side copy: no download/upload round trip, and it renames in the same call.
            Copy-PnPFile -SourceUrl $source.ServerRelativeUrl -TargetUrl $target -Force -OverwriteIfAlreadyExists -ErrorAction Stop | Out-Null
            $copied++
            $results.Add([pscustomobject]@{ SourceFile = $entry.SourceFile; TargetName = $entry.TargetName; Document = $entry.DocumentName; Status = "Copied" })
        } catch {
            $failed++
            $results.Add([pscustomobject]@{ SourceFile = $entry.SourceFile; TargetName = $entry.TargetName; Document = $entry.DocumentName; Status = "Failed"; Message = $_.Exception.Message })
            Write-MarkstrataLog -Message "Copy failed for '$($entry.SourceFile)' -> '$($entry.TargetName)': $($_.Exception.Message)" -Level Error -Component "Attachment"
        }
        Write-Progress -Activity "Moving attachments" -Status "$index of $($toMove.Count)" -PercentComplete ([int](100 * $index / [Math]::Max(1, $toMove.Count)))
    }
    Write-Progress -Activity "Moving attachments" -Completed

    # --- Repoint the Markdown -------------------------------------------------------------------
    # Per document, per reference: the destination is a NEW name, so this is a targeted rewrite of
    # each image URL rather than a swap of the shared base.
    $rewritten = 0
    if (-not $SkipRewrite) {
        $newBaseEncoded = $targetFolderUrl -replace ' ', '%20'
        foreach ($group in ($plan | Group-Object DocumentPath)) {
            $documentPath = $group.Name
            if ([string]::IsNullOrWhiteSpace($documentPath)) { continue }
            $text = Get-Content -LiteralPath $documentPath -Raw
            if ([string]::IsNullOrEmpty($text)) { continue }
            $original = $text

            foreach ($entry in $group.Group) {
                # Replace any image destination whose file name matches this source, whatever base
                # or encoding it currently uses.
                $escaped = [regex]::Escape($entry.SourceFile) -replace '\\ ', '(?:\\ |%20)'
                $pattern = '(!\[[^\]]*\]\()(?:[^()\s]|\([^()]*\))*?' + $escaped + '(\))'
                $text = [regex]::Replace($text, $pattern, ('${1}' + "$newBaseEncoded/$($entry.TargetName)" + '${2}'))
            }

            if ($text -ne $original) {
                if ($PSCmdlet.ShouldProcess($documentPath, "Repoint image links")) {
                    Set-Content -LiteralPath $documentPath -Value $text -Encoding utf8NoBOM -NoNewline
                }
                $rewritten++
            }
        }
        Write-MarkstrataLog -Message "Repointed image links in $rewritten document(s) to $targetFolderUrl." -Component "Attachment"
    }

    if ($PassThru) { return $results }

    return [pscustomobject]@{
        TargetFolder       = $targetFolderUrl
        Copied             = $copied
        Skipped            = $skipped
        Failed             = $failed
        DocumentsRewritten = $rewritten
        OrphansLeft        = $(if ($IncludeOrphan) { 0 } else { $usage.Orphaned.Count })
    }
}
