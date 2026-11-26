#requires -Version 7.4
[CmdletBinding()]
param([switch]$AllowInteraction,[int]$TimeoutSeconds=30,[long]$WindowHandle=0,[ValidateSet('Read','List','Refresh','SignIn','SelectAccount')][string]$Action='Read',[string]$AccountUsername)
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
$VerbosePreference='SilentlyContinue'
$DebugPreference='SilentlyContinue'
$InformationPreference='SilentlyContinue'
$WarningPreference='SilentlyContinue'
try {
    if ($env:GET_PRIVATE_WORKER -cne '1' -or -not [Console]::IsOutputRedirected) { throw 'private_worker_required' }
    . (Join-Path $PSScriptRoot '../src/GraphExplorerToken/Private/Browser.ps1')
    $token = Read-GETBrowserToken -AllowInteraction:$AllowInteraction -TimeoutSeconds $TimeoutSeconds -WindowHandle $WindowHandle -Action $Action -AccountUsername $AccountUsername
    if ($Action -eq 'List') { [Console]::Out.WriteLine((@{windows=@($token)} | ConvertTo-Json -Depth 4 -Compress)); exit 0 }
    if ($Action -in @('SignIn','SelectAccount')) { [Console]::Out.WriteLine((@{result=$token} | ConvertTo-Json -Depth 5 -Compress)); exit 0 }
    if (-not $token) { throw 'token_not_visible' }
    [Console]::Out.WriteLine((@{access_token=$token} | ConvertTo-Json -Compress))
    $token=$null
    exit 0
} catch {
    $code=$_.Exception.Message
    if ($code -cnotin @('private_worker_required','unsupported_platform','browser_unavailable','browser_timeout','browser_confirmation_required','graph_explorer_tab_not_found','browser_origin_not_verified','ambiguous_explorer_windows','token_not_visible','ambiguous_token_controls','control_not_actionable','desktop_in_use')) { $code='token_worker_failed' }
    [Console]::Out.WriteLine((@{code=$code} | ConvertTo-Json -Compress))
    exit 2
}
