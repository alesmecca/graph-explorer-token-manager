#requires -Version 7.4
[CmdletBinding()]
param(
    [ValidateSet('Accounts','Status','Request','Clear')][string]$Action='Accounts',
    [guid]$ProfileId,
    [string]$Path='/v1.0/me',
    [ValidateSet('GET','HEAD','POST','PATCH','PUT','DELETE')][string]$Method='GET',
    [string]$BodyFile,
    [switch]$CacheOnly
)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot '../src/GraphExplorerToken/GraphExplorerToken.psd1') -Force
try {
    if ($Action -ne 'Accounts' -and $ProfileId -eq [guid]::Empty) {throw 'invalid_profile'}
    $result=switch ($Action) {
        'Accounts' {@(Get-GraphAccount)}
        'Status' {Get-GraphAccountStatus -ProfileId $ProfileId}
        'Clear' {Clear-GraphAccountToken -ProfileId $ProfileId; @{Status='cleared'}}
        'Request' {
            $options=@{ProfileId=$ProfileId; Path=$Path; Method=$Method; CacheOnly=$CacheOnly}
            if ($BodyFile) {if ((Get-Item -LiteralPath $BodyFile).Length -gt 1048576) {throw 'invalid_request_body'}; $options.Body=Get-Content -LiteralPath $BodyFile -Raw}
            Invoke-GraphAccountRequest @options
        }
    }
    ConvertTo-Json -InputObject $result -Depth 64
    exit 0
} catch {
    $code=$_.Exception.Message
    if ($code -cnotmatch '^[a-z_]{3,80}$') {$code='operation_failed'}
    @{error=$code} | ConvertTo-Json -Compress
    if ($code -in @('interaction_required','browser_confirmation_required','token_expired','graph_unauthorized','wrong_account','wrong_tenant','required_scopes_missing','graph_forbidden')) {exit 2}
    if ($code -in @('invalid_profile','profile_not_found','profile_store_invalid','cache_corrupt','invalid_graph_path','invalid_request_body')) {exit 3}
    if ($code -in @('graph_unavailable','graph_throttled')) {exit 4}
    exit 5
} finally {Clear-GraphExplorerToken; Clear-GraphAccountDiscovery}
