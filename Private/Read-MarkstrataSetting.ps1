function Read-MarkstrataSetting {
    <#
    .SYNOPSIS
        Ask for one setting, offering the current value as the default.

    .DESCRIPTION
        Read-Host has no notion of a default, so the prompt carries it and an empty answer means
        "keep what is there". Without that, reviewing the configuration would mean retyping every
        value to get past it.

    .PARAMETER Prompt
        What to ask for.

    .PARAMETER Current
        The current value, offered as the default.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [AllowEmptyString()][string]$Current = ""
    )

    $suffix = if ($Current) { " [$Current]" } else { "" }
    $answer = Read-Host -Prompt "$Prompt$suffix"
    if ([string]::IsNullOrWhiteSpace($answer)) { return $Current }
    return $answer.Trim()
}
