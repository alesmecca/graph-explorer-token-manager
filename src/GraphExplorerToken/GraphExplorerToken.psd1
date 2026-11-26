@{
    RootModule = 'GraphExplorerToken.psm1'
    ModuleVersion = '2.0.0'
    GUID = '91af31af-5ec2-48a0-b2bc-5a679d168193'
    Author = 'alesmecca'
    Description = 'Graph Explorer account onboarding, protected token reuse and PowerShell automation without an app registration.'
    PowerShellVersion = '7.4'
    CompatiblePSEditions = @('Core')
    FunctionsToExport = @('New-GraphExplorerProfile','Connect-GraphExplorerToken','Get-GraphExplorerToken','Get-GraphExplorerTokenInfo','Clear-GraphExplorerToken','Test-GraphExplorerEnvironment','Open-GraphExplorer','Get-GraphExplorerWindow','Start-GraphExplorerSignIn','Select-GraphSignInAccount','New-GraphAccountDiscovery','Clear-GraphAccountDiscovery','Save-GraphAccount','Get-GraphAccount','Set-GraphAccount','Remove-GraphAccount','Clear-GraphAccountToken','Get-GraphAccountToken','Get-GraphAccountStatus','Invoke-GraphAccountRequest')
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
