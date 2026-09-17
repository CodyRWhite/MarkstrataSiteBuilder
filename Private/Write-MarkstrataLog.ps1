function Initialize-MarkstrataLog {
    <#
    .SYNOPSIS
        Resolve (and create) this run's CMTrace log file, writing a session header the first
        time it is touched in the process.

    .DESCRIPTION
        One timestamped file PER RUN (never overwritten) under
        %APPDATA%\MarkstrataSiteBuilder\logs, named
        MarkstrataSiteBuilder_<yyyyMMdd_HHmmss>_<pid>.log (per the Logging Standard).
        On first touch the directory is created, old logs are pruned (retention), and a
        self-describing banner is written so a bare log identifies its run.
    #>
    [CmdletBinding()]
    param()

    if ($script:LogFile) { return $script:LogFile }

    if (-not (Test-Path -LiteralPath $script:LogRoot)) {
        New-Item -ItemType Directory -Force -Path $script:LogRoot | Out-Null
    }

    $stamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $script:LogFile = Join-Path $script:LogRoot ("MarkstrataSiteBuilder_{0}_{1}.log" -f $stamp, $PID)

    # Retention: keep at most 30 files and 30 days (whichever is stricter). Locked files are
    # skipped, never fatal.
    try {
        $cutoff = (Get-Date).AddDays(-30)
        $existing = Get-ChildItem -LiteralPath $script:LogRoot -Filter "MarkstrataSiteBuilder_*.log" -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending
        $index = 0
        foreach ($logFile in $existing) {
            $index++
            if ($index -gt 30 -or $logFile.LastWriteTime -lt $cutoff) {
                Remove-Item -LiteralPath $logFile.FullName -Force -ErrorAction SilentlyContinue
            }
        }
    } catch {
        Write-Verbose "Log retention prune skipped: $($_.Exception.Message)"
    }

    $module        = Get-Module MarkstrataSiteBuilder
    $moduleVersion = if ($module) { $module.Version.ToString() } else { "0.0.0" }
    $separator     = "=" * 64
    $headerLines = @(
        $separator,
        "MarkstrataSiteBuilder - run start",
        "Start time : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')",
        "User       : $env:USERDOMAIN\$env:USERNAME",
        "Machine    : $env:COMPUTERNAME ($([System.Environment]::OSVersion.VersionString))",
        "Module     : MarkstrataSiteBuilder $moduleVersion",
        "PowerShell : $($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition))",
        "Process ID : $PID",
        "Log file   : $script:LogFile (one file per run, retention 30 files / 30 days)",
        $separator
    )
    foreach ($headerLine in $headerLines) {
        Write-MarkstrataLog -Message $headerLine -Level Info -Component "Session" -NoConsole
    }

    return $script:LogFile
}

function Write-MarkstrataLog {
    <#
    .SYNOPSIS
        Append one CMTrace-formatted line to the run log (and echo to console).

    .DESCRIPTION
        A per-run log file is written under %APPDATA%\MarkstrataSiteBuilder\
        logs, one file per run. CMTrace formatting opens
        cleanly in CMTrace / OneTrace with severity colouring. The console echo is suppressed
        when $script:LogQuiet is set.

    .PARAMETER Message      The text to log.
    .PARAMETER Level        Info | Warning | Error  (maps to CMTrace type 1/2/3).
    .PARAMETER Component    Short tag for the CMTrace 'component' column.
    .PARAMETER NoConsole    Write only to the file, never the console.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [AllowEmptyString()]
        [string]$Message,

        [ValidateSet("Info", "Warning", "Error")]
        [string]$Level = "Info",

        [string]$Component = "Markstrata",

        [switch]$NoConsole
    )

    if (-not $script:LogFile) { Initialize-MarkstrataLog | Out-Null }

    $cmTraceSeverity = switch ($Level) { "Warning" { 2 } "Error" { 3 } default { 1 } }

    $now = [DateTimeOffset]::Now
    $utcOffsetMinutes = [int]$now.Offset.TotalMinutes
    $offsetSign = if ($utcOffsetMinutes -ge 0) { "+" } else { "-" }
    $timeField = "{0}.{1:000}{2}{3:000}" -f $now.ToString("HH:mm:ss"), $now.Millisecond, $offsetSign, [math]::Abs($utcOffsetMinutes)
    $dateField = $now.ToString("MM-dd-yyyy")
    $threadId  = [System.Threading.Thread]::CurrentThread.ManagedThreadId

    $callerFrame = (Get-PSCallStack | Select-Object -Skip 1 -First 1)
    $sourceReference = if ($callerFrame -and $callerFrame.ScriptName) {
        "{0}:{1}" -f (Split-Path $callerFrame.ScriptName -Leaf), $callerFrame.ScriptLineNumber
    } else { "MarkstrataSiteBuilder" }

    $singleLineMessage = ($Message -replace "\r\n", " | ") -replace "\n", " | "

    $cmTraceLine = '<![LOG[{0}]LOG]!><time="{1}" date="{2}" component="{3}" context="{4}" type="{5}" thread="{6}" file="{7}">' -f `
        $singleLineMessage, $timeField, $dateField, $Component, "$env:USERDOMAIN\$env:USERNAME", $cmTraceSeverity, $threadId, $sourceReference

    for ($writeAttempt = 0; $writeAttempt -lt 3; $writeAttempt++) {
        try {
            # -WhatIf:$false so a caller's -WhatIf suppresses the SharePoint writes it is meant to,
            # not the run log that records what would have happened.
            Add-Content -LiteralPath $script:LogFile -Value $cmTraceLine -Encoding UTF8 -ErrorAction Stop -WhatIf:$false
            break
        } catch {
            if ($writeAttempt -eq 2) { Write-Warning "Could not write log: $($_.Exception.Message)" }
            else { Start-Sleep -Milliseconds 100 }
        }
    }

    if (-not $NoConsole -and -not $script:LogQuiet) {
        $consoleColor = switch ($Level) { "Warning" { "Yellow" } "Error" { "Red" } default { "Gray" } }
        Write-Host ("{0} {1,-7} {2}: {3}" -f $now.ToString("HH:mm:ss"), $Level.ToUpper(), $Component, $Message) -ForegroundColor $consoleColor
    }
}
