@{
    RootModule = 'GraphExplorerToken.psm1'
    ModuleVersion = '1.0.0'
    GUID = '91af31af-5ec2-48a0-b2bc-5a679d168193'
    Author = 'alesmecca'
    Description = 'Recover your visible Microsoft Graph Explorer token with explicit identity binding and memory-only storage.'
    PowerShellVersion = '7.4'
    CompatiblePSEditions = @('Core')
    FunctionsToExport = @('New-GraphExplorerProfile','Connect-GraphExplorerToken','Get-GraphExplorerToken','Get-GraphExplorerTokenInfo','Clear-GraphExplorerToken','Test-GraphExplorerEnvironment','Open-GraphExplorer')
    CmdletsToExport = @()
    VariablesToExport = @()
    AliasesToExport = @()
    PrivateData = @{
        PSData = @{
            Tags = @('MicrosoftGraph','GraphExplorer','Windows','Token')
            LicenseUri = 'https://github.com/alesmecca/graph-explorer-token-manager/blob/main/LICENSE'
            ProjectUri = 'https://github.com/alesmecca/graph-explorer-token-manager'
        }
    }
}
