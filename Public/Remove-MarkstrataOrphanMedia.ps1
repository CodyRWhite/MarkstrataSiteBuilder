function Remove-MarkstrataOrphanMedia {
    <#
    .SYNOPSIS
        Recycle attachments that no Markdown document references.

    .DESCRIPTION
        The page sweeps (Publish-MarkstrataLibrary -RemoveOrphan, Remove-MarkstrataLegacyPage) only ever
        look at pages. Attachments live in their own library and nothing was watching them, so
        images belonging to documents that have since been retired or rewritten simply accumulate.

        An attachment counts as orphaned when no .md in the library references its FILE NAME.
        Matching on the name rather than the full URL means moving the attachments (see
        Move-MarkstrataMedia) does not make every one of them look unreferenced.

        Deletion is a RECYCLE: items land in the site recycle bin and can be restored for 93 days.

    .PARAMETER LibraryRoot
        Local root of the synced document library. Defaults to markdown.libraryRoot.

    .PARAMETER AttachmentLibrary
        Library to sweep. Defaults to markdown.legacyMediaLibrary, which is empty unless you are migrating out of an older image library - so normally this is passed explicitly.

    .PARAMETER Keep
        File names to preserve regardless.

    .PARAMETER Force
        Skip the confirmation prompt. -WhatIf still wins.

    .PARAMETER PassThru
        Emit one object per attachment instead of only the summary.

    .OUTPUTS
        PSCustomObject summary (Examined, InUse, Recycled, Kept, Failed, FreedMB).

    .EXAMPLE
        Remove-MarkstrataOrphanMedia -WhatIf

        List every attachment that would be recycled, and how much space it frees.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = "High")]
    [OutputType([pscustomobject])]
    param(
        [string]$LibraryRoot,

        [string]$AttachmentLibrary,

        [string[]]$Keep = @(),

        [switch]$Force,

        [switch]$PassThru
    )

    if (-not $script:SharePointReady) {
        throw "Not connected. Run Connect-MarkstrataSite first."
    }

    # -Force is the caller saying "don't ask"; ConfirmImpact High would otherwise prompt per item,
    # which is fatal in a non-interactive host.
    if ($Force -and -not $PSBoundParameters.ContainsKey("Confirm")) {
        $ConfirmPreference = "None"
    }

    $config = Get-MarkstrataConfig
    if ([string]::IsNullOrWhiteSpace($AttachmentLibrary)) {
        $AttachmentLibrary = [string](Get-OptionalProperty $config.Markdown "legacyMediaLibrary" "")
    }
    if ([string]::IsNullOrWhiteSpace($AttachmentLibrary)) {
        throw "No media library given. Pass -AttachmentLibrary, or set markdown.legacyMediaLibrary."
    }

    $usageArguments = @{ AttachmentLibrary = $AttachmentLibrary }
    if ($LibraryRoot) { $usageArguments["LibraryRoot"] = $LibraryRoot }
    $usage = Get-MarkstrataMediaUsage @usageArguments

    $keepNames = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($name in $Keep) { if ($name) { [void]$keepNames.Add($name) } }

    $candidates = @($usage.Orphaned | Where-Object { -not $keepNames.Contains($_.Name) })
    $kept = @($usage.Orphaned).Count - $candidates.Count
    $freedBytes = ($candidates | Measure-Object Size -Sum).Sum
    if (-not $freedBytes) { $freedBytes = 0 }

    Write-MarkstrataLog -Message ("Attachment sweep on '{0}': {1} in use, {2} orphaned ({3} MB), {4} kept by -Keep." -f `
        $AttachmentLibrary, $usage.InUse.Count, $candidates.Count, [math]::Round($freedBytes / 1MB, 1), $kept) -Component "Attachment"

    if ($candidates.Count -eq 0) {
        return [pscustomobject]@{ Examined = $usage.InUse.Count + $usage.Orphaned.Count; InUse = $usage.InUse.Count; Recycled = 0; Kept = $kept; Failed = 0; FreedMB = 0 }
    }

    if (-not $Force -and -not $WhatIfPreference) {
        $prompt = "Recycle $($candidates.Count) unreferenced attachment(s) from ${AttachmentLibrary}, freeing $([math]::Round($freedBytes/1MB,1)) MB? They can be restored from the site recycle bin for 93 days."
        $proceed = $false
        try { $proceed = $PSCmdlet.ShouldContinue($prompt, "Remove orphaned attachments") }
        catch { throw "This session cannot prompt for confirmation. Re-run with -WhatIf to preview, or -Force to proceed: $($_.Exception.Message)" }
        if (-not $proceed) {
            Write-MarkstrataLog -Message "Attachment sweep cancelled by the operator." -Level Warning -Component "Attachment"
            return [pscustomobject]@{ Examined = $usage.InUse.Count + $usage.Orphaned.Count; InUse = $usage.InUse.Count; Recycled = 0; Kept = $kept; Failed = 0; FreedMB = 0 }
        }
    }

    $results = [System.Collections.Generic.List[object]]::new()
    $recycled = 0; $failed = 0; $index = 0
    foreach ($attachment in $candidates) {
        $index++
        if (-not $PSCmdlet.ShouldProcess($attachment.ServerRelativeUrl, "Recycle orphaned attachment")) {
            $results.Add([pscustomobject]@{ Name = $attachment.Name; Status = "WhatIf"; SizeKB = [math]::Round($attachment.Size / 1KB) })
            continue
        }
        try {
            Move-PnPListItemToRecycleBin -List $AttachmentLibrary -Identity $attachment.Id -Force -ErrorAction Stop | Out-Null
            $recycled++
            $results.Add([pscustomobject]@{ Name = $attachment.Name; Status = "Recycled"; SizeKB = [math]::Round($attachment.Size / 1KB) })
        } catch {
            $failed++
            $results.Add([pscustomobject]@{ Name = $attachment.Name; Status = "Failed"; Message = $_.Exception.Message })
            Write-MarkstrataLog -Message "Recycle failed for '$($attachment.Name)': $($_.Exception.Message)" -Level Error -Component "Attachment"
        }
        Write-Progress -Activity "Removing orphaned attachments" -Status "$index of $($candidates.Count)" -PercentComplete ([int](100 * $index / $candidates.Count))
    }
    Write-Progress -Activity "Removing orphaned attachments" -Completed

    Write-MarkstrataLog -Message ("Attachment sweep complete: {0} recycled, {1} failed, {2} MB freed." -f $recycled, $failed, [math]::Round($freedBytes / 1MB, 1)) -Component "Attachment"

    if ($PassThru) { return $results }

    return [pscustomobject]@{
        Examined = $usage.InUse.Count + $usage.Orphaned.Count
        InUse    = $usage.InUse.Count
        Recycled = $recycled
        Kept     = $kept
        Failed   = $failed
        FreedMB  = [math]::Round($freedBytes / 1MB, 1)
    }
}
