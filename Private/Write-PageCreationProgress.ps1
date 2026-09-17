function Write-PageCreationProgress {
    <#
    .SYNOPSIS
        Emit a one-line, per-page progress indicator (with an estimated time remaining) while
        modern pages are being created in SharePoint.

    .DESCRIPTION
        Called once per page by New-SharePointWikiPage. Prints a coloured status line of the form

            [  12/212]  18%  Created      ~3m 40s left   SR Fax Setup Process

        and drives a Write-Progress bar (with -SecondsRemaining) so the host shows a running ETA.
        The ETA is a simple average-pace projection: mean seconds-per-page so far times the number
        of pages left. When TotalPages is 0 (count unknown) it shows a running count without an ETA.

    .PARAMETER PageIndex     1-based number of the page just processed.
    .PARAMETER TotalPages    Total pages this run (0 = unknown -> no ETA).
    .PARAMETER ElapsedSeconds Wall-clock seconds elapsed since the first page started.
    .PARAMETER Status        Created | Overwritten | Skipped | Failed | WhatIf.
    .PARAMETER Leaf          Page name (for the trailing detail).
    .PARAMETER ErrorMessage  Failure detail, appended when Status is Failed.
    #>
    [CmdletBinding()]
    param(
        [int]$PageIndex,
        [int]$TotalPages,
        [double]$ElapsedSeconds,
        [string]$Status,
        [string]$Leaf,
        [string]$ErrorMessage
    )

    $statusColor = switch ($Status) {
        "Failed"      { "Red" }
        "Skipped"     { "DarkGray" }
        "Overwritten" { "Yellow" }
        "WhatIf"      { "DarkGray" }
        default       { "Green" }
    }

    if ($TotalPages -gt 0) {
        $percentComplete = [int](($PageIndex / $TotalPages) * 100)
        $remainingPages  = [Math]::Max(0, $TotalPages - $PageIndex)
        $averageSeconds  = if ($PageIndex -gt 0) { $ElapsedSeconds / $PageIndex } else { 0 }
        $etaSeconds      = [int]($averageSeconds * $remainingPages)
        $etaSpan         = [TimeSpan]::FromSeconds($etaSeconds)

        $etaText = if ($remainingPages -eq 0) { "done" }
                   elseif ($etaSpan.TotalHours -ge 1) { "~{0}h {1:00}m left" -f [int]$etaSpan.TotalHours, $etaSpan.Minutes }
                   elseif ($etaSpan.TotalMinutes -ge 1) { "~{0}m {1:00}s left" -f $etaSpan.Minutes, $etaSpan.Seconds }
                   else { "~{0}s left" -f $etaSeconds }

        $counter = "[{0,4}/{1}]" -f $PageIndex, $TotalPages
        $line    = "{0} {1,3}%  {2,-11} {3,-14} {4}" -f $counter, $percentComplete, $Status, $etaText, $Leaf
    }
    else {
        $percentComplete = -1
        $etaSeconds      = -1
        $line            = "[{0,4}]  {1,-11} {2}" -f $PageIndex, $Status, $Leaf
    }

    if ($Status -eq "Failed" -and $ErrorMessage) { $line = "$line  --  $ErrorMessage" }

    Write-Host $line -ForegroundColor $statusColor

    if ($TotalPages -gt 0) {
        Write-Progress -Activity "Creating SharePoint pages" `
            -Status ("{0} of {1} ({2}%)" -f $PageIndex, $TotalPages, $percentComplete) `
            -PercentComplete $percentComplete -SecondsRemaining $etaSeconds
    }
    else {
        Write-Progress -Activity "Creating SharePoint pages" -Status ("Page {0}" -f $PageIndex)
    }
}
