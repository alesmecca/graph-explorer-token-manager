#requires -Version 7.4
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '../src/GraphExplorerToken/Private/Browser.ps1')
$valid=@('https://developer.microsoft.com/graph/graph-explorer','https://developer.microsoft.com/en-us/graph/graph-explorer/','https://developer.microsoft.com/it-it/graph/graph-explorer?request=me')
$invalid=@('http://developer.microsoft.com/graph/graph-explorer','https://developer.microsoft.com.evil.example/graph/graph-explorer','https://developer.microsoft.com@evil.example/graph/graph-explorer','https://user@developer.microsoft.com/graph/graph-explorer','https://developer.microsoft.com:444/graph/graph-explorer','https://developer.microsoft.com/graph/graph-explorer/evil','https://developer.microsoft.com/other','file:///graph/graph-explorer','https://developer.microsoft.com\@evil.example/graph/graph-explorer')
foreach ($address in $valid) {if (-not (Test-GETExplorerAddress $address)) {throw 'Valid origin rejected'}}
foreach ($address in $invalid) {if (Test-GETExplorerAddress $address) {throw 'Unsafe origin accepted'}}
# This worker invocation cannot read the desktop: its private transport guard fails first.
$previous=$env:GET_PRIVATE_WORKER
try {
    $env:GET_PRIVATE_WORKER=$null
    $result=& (Join-Path $PSHOME 'pwsh') -NoProfile -File (Join-Path $PSScriptRoot '../scripts/Read-BrowserToken.ps1') | ConvertFrom-Json
    if ($LASTEXITCODE -ne 2 -or $result.code -ne 'private_worker_required') {throw 'Worker transport guard failed'}
} finally {$env:GET_PRIVATE_WORKER=$previous}
Write-Host 'Browser contract: 12 origin cases and private transport guard passed; no desktop access.'
