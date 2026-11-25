#requires -Version 7.4
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$parseFailures=0
foreach ($file in Get-ChildItem -LiteralPath $root -Recurse -File -Include *.ps1,*.psm1,*.psd1) {
    $parseErrors=$null
    $null=[Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$null,[ref]$parseErrors)
    if ($parseErrors.Count) {$parseFailures++; Write-Host "Parse failure: $($file.Name)"}
}
if ($parseFailures) {throw 'PowerShell parsing failed'}
$null=Test-ModuleManifest (Join-Path $root 'src/GraphExplorerToken/GraphExplorerToken.psd1')
foreach ($test in @('Test-Core.ps1','Test-Http.ps1','Test-BrowserContract.ps1')) {
    & (Join-Path $PSHOME 'pwsh') -NoProfile -File (Join-Path $root "tests/$test")
    if ($LASTEXITCODE -ne 0) {throw "Failed: $test"}
}
if ($IsWindows) {
    & (Join-Path $PSHOME 'pwsh') -NoProfile -STA -File (Join-Path $PSScriptRoot 'Start-TokenManager.ps1') -SmokeTest
    if ($LASTEXITCODE -ne 0) {throw 'GUI construction failed'}
}
Write-Host 'All offline checks passed.'
