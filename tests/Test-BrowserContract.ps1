#requires -Version 7.4
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '../src/GraphExplorerToken/Private/Browser.ps1')
if ($IsWindows) {Initialize-GETNativeInvoke} # Compile the async UIA adapter without accessing a desktop.
$valid=@('https://developer.microsoft.com/graph/graph-explorer','https://developer.microsoft.com/en-us/graph/graph-explorer/','https://developer.microsoft.com/it-it/graph/graph-explorer?request=me')
$invalid=@('http://developer.microsoft.com/graph/graph-explorer','https://developer.microsoft.com.evil.example/graph/graph-explorer','https://developer.microsoft.com@evil.example/graph/graph-explorer','https://user@developer.microsoft.com/graph/graph-explorer','https://developer.microsoft.com:444/graph/graph-explorer','https://developer.microsoft.com/graph/graph-explorer/evil','https://developer.microsoft.com/other','file:///graph/graph-explorer','https://developer.microsoft.com\@evil.example/graph/graph-explorer')
foreach ($address in $valid) {if (-not (Test-GETExplorerAddress $address)) {throw 'Valid origin rejected'}}
foreach ($address in $invalid) {if (Test-GETExplorerAddress $address) {throw 'Unsafe origin accepted'}}
$signInValid=@('https://login.microsoftonline.com/common/oauth2/v2.0/authorize','https://login.live.com/oauth20_authorize.srf')
$signInInvalid=@('http://login.microsoftonline.com/common','https://login.microsoftonline.com.evil.invalid/common','https://login.microsoftonline.com@evil.invalid/common','https://user@login.microsoftonline.com/common','https://login.live.com:444/','https://developer.microsoft.com/graph/graph-explorer','file:///login.microsoftonline.com')
foreach ($address in $signInValid) {if (-not (Test-GETSignInAddress $address)) {throw 'Valid sign-in origin rejected'}}
foreach ($address in $signInInvalid) {if (Test-GETSignInAddress $address) {throw 'Unsafe sign-in origin accepted'}}
$graphLogin='https://login.microsoftonline.com/common/oauth2/v2.0/authorize?client_id=de8bc8b5-d9f9-48b1-a8ad-b748da725064'
if (-not (Test-GETGraphLoginAddress $graphLogin)) {throw 'Graph Explorer sign-in not recognized'}
foreach ($address in @('https://login.microsoftonline.com/common','https://login.microsoftonline.com/common?client_id=11111111-1111-4111-8111-111111111111',($graphLogin+'&client_id=other'),$graphLogin.Replace('login.microsoftonline.com','evil.invalid'))) {if (Test-GETGraphLoginAddress $address) {throw 'Unrelated sign-in window accepted'}}
$promptCases=@(
    @{Title='Ricarica sito?'; Buttons=@('Ricarica','Annulla'); Depth=0; Expected=$true},
    @{Title='Reload site?'; Buttons=@('Reload','Cancel'); Depth=0; Expected=$true},
    @{Title='Ricarica sito?'; Buttons=@('Ricarica','Annulla'); Depth=1; Expected=$false},
    @{Title='Ricarica sito?'; Buttons=@('Ricarica','Annulla'); Depth=-1; Expected=$false},
    @{Title='Sign in'; Buttons=@('Reload','Cancel'); Depth=0; Expected=$false},
    @{Title='Reload site?'; Buttons=@('Reload'); Depth=0; Expected=$false},
    @{Title='Reload site?'; Buttons=@('Reload','Cancel','Reload'); Depth=0; Expected=$false}
)
foreach ($case in $promptCases) {if ((Test-GETReloadConfirmation $case.Title $case.Buttons $case.Depth) -ne $case.Expected) {throw 'Native browser confirmation classification failed'}}
# This worker invocation cannot read the desktop: its private transport guard fails first.
$previous=$env:GET_PRIVATE_WORKER
try {
    $env:GET_PRIVATE_WORKER=$null
    $result=& (Join-Path $PSHOME 'pwsh') -NoProfile -File (Join-Path $PSScriptRoot '../scripts/Read-BrowserToken.ps1') | ConvertFrom-Json
    if ($LASTEXITCODE -ne 2 -or $result.code -ne 'private_worker_required') {throw 'Worker transport guard failed'}
} finally {$env:GET_PRIVATE_WORKER=$previous}
Write-Host 'Browser contract: 26 origin/application cases, 7 native prompt cases and private transport guard passed; no desktop access.'
