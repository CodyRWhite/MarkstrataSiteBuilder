function Get-OptionalProperty {
    <#
    .SYNOPSIS
        Safely read a property that may be absent, returning a default instead of throwing.

    .DESCRIPTION
        The module runs under Set-StrictMode -Version Latest, which throws on access to a
        non-existent property. Config sections omit keys that were never set, and API responses
        omit properties that are empty rather than returning null, so every optional read goes
        through this helper. It also reaches property names that are awkward to write inline, such
        as the "AzureAppId/ClientId" a PnP registration returns.

    .PARAMETER InputObject
        The object to read from.

    .PARAMETER Name
        The property name.

    .PARAMETER Default
        Value returned when the object is null or lacks the property (default: $null).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        $InputObject,

        [Parameter(Mandatory, Position = 1)]
        [string]$Name,

        [Parameter(Position = 2)]
        $Default = $null
    )

    if ($null -ne $InputObject -and $InputObject.PSObject.Properties.Name -contains $Name) {
        return $InputObject.$Name
    }
    return $Default
}
