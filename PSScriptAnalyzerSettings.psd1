@{
    # Lint settings for MarkstrataSiteBuilder. Run:  Invoke-ScriptAnalyzer -Path . -Recurse -Settings .\PSScriptAnalyzerSettings.psd1
    Severity = @('Error', 'Warning')

    ExcludeRules = @(
        # The module deliberately writes user-facing progress/status to the host;
        # structured logging goes through Write-MarkstrataLog (file + host by design).
        'PSAvoidUsingWriteHost',
        # New-SharePointWikiPage / Convert-WikiPageToHtml take a SharePoint cmdlet's own
        # ShouldProcess where state actually changes; pure shaping helpers do not.
        'PSUseShouldProcessForStateChangingFunctions',
        # UTF-8 WITHOUT BOM (a BOM breaks Import-Module on
        # CLM/constrained-language endpoints). Do not require a BOM.
        'PSUseBOMForUnicodeEncodedFile'
    )
}
