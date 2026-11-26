#requires -Version 7.4
param([string]$ChildProfileId,[string]$ChildHome)
$ErrorActionPreference='Stop'
if (-not $IsWindows) {throw 'DPAPI integration tests require Windows'}
$modulePath=Join-Path $PSScriptRoot '../src/GraphExplorerToken/GraphExplorerToken.psd1'
$module=Import-Module $modulePath -Force -PassThru
Add-Type -TypeDefinition @'
using System;
using System.Net;
using System.Net.Http;
using System.Threading;
using System.Threading.Tasks;
public class AccountGraphHandler : HttpClientHandler {
    public static int Calls, ApiCalls, ApiStatus=200, IdentityStatus=200;
    public static string UserId="22222222-2222-4222-8222-222222222222";
    public static string Address, Method;
    public static bool Redirects, Bearer;
    protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellation) {
        Calls++; Address=request.RequestUri.ToString(); Method=request.Method.Method;
        Redirects=AllowAutoRedirect; Bearer=request.Headers.Authorization?.Scheme=="Bearer";
        bool identity=request.RequestUri.AbsolutePath=="/v1.0/me";
        if (!identity) ApiCalls++;
        int status=identity ? IdentityStatus : ApiStatus;
        string body=identity ? "{\"id\":\""+UserId+"\",\"displayName\":\"Offline User\",\"userPrincipalName\":\"test@example.invalid\"}" : "{\"value\":[{\"ok\":true}]}";
        return Task.FromResult(new HttpResponseMessage((HttpStatusCode)status){Content=new StringContent(body)});
    }
}
'@
& $module {function script:New-GETHttpHandler {[AccountGraphHandler]::new()}}
if ($ChildProfileId) {
    $env:GRAPH_TOKEN_MANAGER_HOME=$ChildHome
    & $module {function script:Invoke-GETBrowserWorker {throw 'unexpected_browser'}}
    $token=Get-GraphAccountToken -ProfileId $ChildProfileId -CacheOnly
    try {if (-not $token.IsReadOnly() -or [AccountGraphHandler]::Calls -ne 1) {throw 'child_contract_failed'}} finally {$token.Dispose()}
    Write-Host 'child_dpapi_verified'; exit 0
}
$priorHome=$env:GRAPH_TOKEN_MANAGER_HOME
$testRoot=Join-Path ([IO.Path]::GetTempPath()) ('GraphExplorerTokenTests-'+[guid]::NewGuid())
$env:GRAPH_TOKEN_MANAGER_HOME=$testRoot
$null=New-Item -ItemType Directory -Path $testRoot
$state=@{Raw=''; BrowserCalls=0; RefreshCalls=0; Fail=$null}
& $module {param($s) $script:OfflineState=$s; function script:Invoke-GETBrowserWorker {param($WindowHandle,[switch]$AllowInteraction,$Action='Read',$TimeoutSeconds) $script:OfflineState.BrowserCalls++; if ($Action -eq 'Refresh') {$script:OfflineState.RefreshCalls++}; if ($script:OfflineState.Fail) {throw $script:OfflineState.Fail}; $script:OfflineState.Raw}} $state
$tenant='11111111-1111-4111-8111-111111111111'; $oid='22222222-2222-4222-8222-222222222222'; $other='33333333-3333-4333-8333-333333333333'
$script:passed=0; $script:failed=0
function Assert($Value,[string]$Message='assertion_failed') {if (-not $Value) {throw $Message}}
function Reject([scriptblock]$Action,[string]$Code) { $failure=$null; try {& $Action | Out-Null} catch {$failure=$_}; Assert ($null -ne $failure) 'expected_failure'; if ($Code) {Assert ($failure.Exception.Message -eq $Code) ('expected_'+$Code+'_received_'+$failure.Exception.Message)} }
function B64([string]$Text) {[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Text)).TrimEnd('=').Replace('+','-').Replace('/','_')}
function Jwt([hashtable]$Changes=@{}) {
    $claims=@{aud='00000003-0000-0000-c000-000000000000';tid=$tenant;oid=$oid;scp='User.Read Mail.Read';exp=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()+3600;canary='DPAPI_OFFLINE_SECRET_CANARY'}
    foreach ($key in $Changes.Keys) {$claims[$key]=$Changes[$key]}
    (B64 '{"alg":"RS256"}')+'.'+(B64 ($claims | ConvertTo-Json -Compress))+'.'+(B64 'synthetic-signature')
}
function Discover([string]$Raw=(Jwt)) {$s=ConvertTo-SecureString $Raw -AsPlainText -Force; try {New-GraphAccountDiscovery -Token $s} finally {$s.Dispose()}}
function Account([switch]$Persist,[switch]$Refresh) {$d=Discover; Save-GraphAccount -DiscoveryId $d.DiscoveryId -Name 'Offline profile' -PersistToken:$Persist -AllowRefresh:$Refresh}
function CachePath($a) {Join-Path $testRoot ($a.ProfileId+'.bin')}
function Test([string]$Name,[scriptblock]$Action) {
    Clear-GraphExplorerToken; Clear-GraphAccountDiscovery
    $state.Raw=Jwt; $state.BrowserCalls=0; $state.RefreshCalls=0; $state.Fail=$null
    [AccountGraphHandler]::Calls=0; [AccountGraphHandler]::ApiCalls=0; [AccountGraphHandler]::ApiStatus=200; [AccountGraphHandler]::IdentityStatus=200; [AccountGraphHandler]::UserId=$oid
    try {& $Action | Out-Null; $script:passed++; Write-Host "PASS $Name"}
    catch {$script:failed++; Write-Host "FAIL $Name : $($_.Exception.Message) at $($_.InvocationInfo.ScriptLineNumber)"}
}
try {
    Test 'First launch has no preconfigured account' {Assert (@(Get-GraphAccount).Count -eq 0)}
    Test 'Discovery verifies identity without saving any file' {$d=Discover; Assert $d.ConfirmationRequired; Assert ($d.Identity.AccountObjectId -eq $oid); Assert ([AccountGraphHandler]::Calls -eq 1); Assert (@(Get-ChildItem $testRoot).Count -eq 0); Assert (($d | ConvertTo-Json -Depth 4) -notmatch 'DPAPI_OFFLINE_SECRET_CANARY|eyJhbG')}
    Test 'Graph identity mismatch cannot create pending discovery' {[AccountGraphHandler]::UserId=$other; Reject {Discover} 'graph_identity_mismatch'; Assert ((& $module {$script:Discoveries.Count}) -eq 0)}
    Test 'Cancel disposes pending and cannot be confirmed' {$d=Discover; $owned=& $module {@($script:Discoveries.Values)[0].Token}; Clear-GraphAccountDiscovery; Reject {$owned.Copy()} ''; Reject {Save-GraphAccount -DiscoveryId $d.DiscoveryId -Name 'Denied'} 'discovery_expired'}
    Test 'Expired confirmation cannot save account' {$d=Discover; & $module {@($script:Discoveries.Values)[0].CreatedAt=[DateTimeOffset]::UtcNow.AddMinutes(-6)}; Reject {Save-GraphAccount -DiscoveryId $d.DiscoveryId -Name 'Denied'} 'discovery_expired'}
    Test 'Memory only is the default' {$a=Account; Assert (-not $a.PersistToken); Assert (-not (Test-Path (CachePath $a))); $t=Get-GraphAccountToken -ProfileId $a.ProfileId; try {Assert ($t -is [Security.SecureString]); Assert $t.IsReadOnly()} finally {$t.Dispose()}}
    Test 'A confirmed discovery cannot be reused' {$d=Discover; $null=Save-GraphAccount -DiscoveryId $d.DiscoveryId -Name 'One'; Reject {Save-GraphAccount -DiscoveryId $d.DiscoveryId -Name 'Two'} 'discovery_expired'}
    Test 'DPAPI round trip and no plaintext in files' {$a=Account -Persist; Assert (Test-Path (CachePath $a)); $stored=& $module {param($a) Read-GETProtectedToken $a} $a; try {Assert ($stored.Token.Length -gt 100)} finally {$stored.Token.Dispose()}; foreach ($f in Get-ChildItem $testRoot -File) {$text=[Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes($f.FullName)); Assert (-not $text.Contains((Jwt))); Assert (-not $text.Contains('DPAPI_OFFLINE_SECRET_CANARY'))}; Assert (@(Get-ChildItem $testRoot -Filter '*.tmp' -Force).Count -eq 0)}
    Test 'Fresh PowerShell process reuses DPAPI and verifies Graph' {$a=Account -Persist; $output=& (Join-Path $PSHOME 'pwsh') -NoProfile -File $PSCommandPath -ChildProfileId $a.ProfileId -ChildHome $testRoot; Assert ($LASTEXITCODE -eq 0); Assert (($output -join '') -match 'child_dpapi_verified')}
    Test 'Corrupt cache fails closed without browser' {$a=Account -Persist; Clear-GraphExplorerToken; $path=CachePath $a; $bytes=[IO.File]::ReadAllBytes($path); $bytes[40]=$bytes[40] -bxor 255; [IO.File]::WriteAllBytes($path,$bytes); Reject {Get-GraphAccountToken -ProfileId $a.ProfileId -CacheOnly} 'cache_corrupt'; Assert ($state.BrowserCalls -eq 0)}
    Test 'Cache copied to another profile is rejected' {$a=Account -Persist; $b=Account -Persist; Clear-GraphExplorerToken; [IO.File]::WriteAllBytes((CachePath $b),[IO.File]::ReadAllBytes((CachePath $a))); Reject {Get-GraphAccountToken -ProfileId $b.ProfileId -CacheOnly} 'cache_corrupt'}
    Test 'Changed profile identity cannot use protected payload' {$a=Account -Persist; Clear-GraphExplorerToken; $path=Join-Path $testRoot ($a.ProfileId+'.json'); $j=Get-Content $path -Raw | ConvertFrom-Json; $j.AccountObjectId=$other; $j | ConvertTo-Json | Set-Content $path; Reject {Get-GraphAccountToken -ProfileId $a.ProfileId -CacheOnly} 'cache_corrupt'}
    Test 'Restored protected token revalidates with Graph' {$a=Account -Persist; Clear-GraphExplorerToken; $before=[AccountGraphHandler]::Calls; $t=Get-GraphAccountToken -ProfileId $a.ProfileId -CacheOnly; $t.Dispose(); Assert ([AccountGraphHandler]::Calls -eq $before+1); Assert ($state.BrowserCalls -eq 0)}
    Test 'Cached process token avoids repeated HTTP' {$a=Account; $before=[AccountGraphHandler]::Calls; $t=Get-GraphAccountToken -ProfileId $a.ProfileId; $t.Dispose(); Assert ([AccountGraphHandler]::Calls -eq $before)}
    Test 'Memory verification older than five minutes revalidates' {$a=Account; & $module {@($script:TokenCache.Values)[0].VerifiedAt=[DateTimeOffset]::UtcNow.AddMinutes(-6)}; $before=[AccountGraphHandler]::Calls; $t=Get-GraphAccountToken -ProfileId $a.ProfileId; $t.Dispose(); Assert ([AccountGraphHandler]::Calls -eq $before+1)}
    Test 'CacheOnly never starts browser when cache is absent' {$a=Account; Clear-GraphExplorerToken; Reject {Get-GraphAccountToken -ProfileId $a.ProfileId -CacheOnly} 'interaction_required'; Assert ($state.BrowserCalls -eq 0)}
    Test 'Disabling persistence deletes protected file' {$a=Account -Persist; $null=Set-GraphAccount -ProfileId $a.ProfileId -PersistToken $false; Assert (-not (Test-Path (CachePath $a))); Assert (-not (Get-GraphAccount $a.ProfileId).PersistToken)}
    Test 'Changing required scopes invalidates previous cache' {$a=Account -Persist; $null=Set-GraphAccount -ProfileId $a.ProfileId -RequiredScopes @('Mail.Read'); Assert (-not (Test-Path (CachePath $a))); Reject {Get-GraphAccountToken -ProfileId $a.ProfileId -CacheOnly} 'interaction_required'}
    Test 'Wrong account from browser cannot replace selected identity' {$a=Account -Persist; $before=[IO.File]::ReadAllBytes((CachePath $a)); $state.Raw=Jwt @{oid=$other}; Reject {Get-GraphAccountToken -ProfileId $a.ProfileId -Force} 'wrong_account'; Assert ([Convert]::ToBase64String($before) -ceq [Convert]::ToBase64String([IO.File]::ReadAllBytes((CachePath $a)))); Assert ($state.RefreshCalls -eq 0)}
    Test 'Refresh disabled never modifies browser after failure' {$a=Account; Clear-GraphExplorerToken; $state.Fail='token_not_visible'; Reject {Get-GraphAccountToken -ProfileId $a.ProfileId} 'interaction_required'; Assert ($state.BrowserCalls -eq 1); Assert ($state.RefreshCalls -eq 0)}
    Test 'Refresh enabled is attempted only once' {$a=Account -Refresh; Clear-GraphExplorerToken; $state.Fail='token_not_visible'; Reject {Get-GraphAccountToken -ProfileId $a.ProfileId} 'token_not_visible'; Assert ($state.BrowserCalls -eq 2); Assert ($state.RefreshCalls -eq 1)}
    Test 'Stale refreshed token is never returned' {$a=Account -Refresh; Clear-GraphExplorerToken; $state.Raw=Jwt @{exp=1}; Reject {Get-GraphAccountToken -ProfileId $a.ProfileId} 'token_expired'; Assert ($state.RefreshCalls -eq 1)}
    Test 'Explicit clear removes memory and protected token' {$a=Account -Persist; Clear-GraphAccountToken -ProfileId $a.ProfileId; Assert (-not (Test-Path (CachePath $a))); Reject {Get-GraphAccountToken -ProfileId $a.ProfileId -CacheOnly} 'interaction_required'; Assert ((Get-GraphAccountStatus $a.ProfileId).Status -eq 'not_connected')}
    Test 'Remove account removes metadata and token' {$a=Account -Persist; Remove-GraphAccount $a.ProfileId; Reject {Get-GraphAccount $a.ProfileId} 'profile_not_found'; Assert (-not (Test-Path (CachePath $a)))}
    Test 'Missing profile fails before browser or HTTP' {Reject {Get-GraphAccountToken -ProfileId ([guid]::NewGuid())} 'profile_not_found'; Assert ($state.BrowserCalls -eq 0); Assert ([AccountGraphHandler]::Calls -eq 0)}
    Test 'Arbitrary graph hosts and malformed paths are refused before acquisition' {
        foreach ($path in @('https://graph.microsoft.com.evil.invalid/v1.0/me','https://graph.microsoft.com@evil.invalid/v1.0/me','http://graph.microsoft.com/v1.0/me','//evil.invalid/v1.0/me','/v1.0/me#secret','/v1.0/me\evil','/v1.0/me%0a','/me','https://graph.microsoft.com:444/v1.0/me')) {Reject {Invoke-GraphAccountRequest -ProfileId ([guid]::NewGuid()) -Path $path} 'invalid_graph_path'}
        Assert ([AccountGraphHandler]::Calls -eq 0); Assert ($state.BrowserCalls -eq 0)
    }
    Test 'Graph wrapper attaches Bearer only to fixed HTTPS host with no redirects' {$a=Account; $data=Invoke-GraphAccountRequest -ProfileId $a.ProfileId -Path '/v1.0/messages'; Assert $data.value[0].ok; Assert [AccountGraphHandler]::Bearer; Assert (-not [AccountGraphHandler]::Redirects); Assert ([AccountGraphHandler]::Address -eq 'https://graph.microsoft.com/v1.0/messages')}
    Test 'Redirect is not followed' {$a=Account; [AccountGraphHandler]::ApiStatus=302; Reject {Invoke-GraphAccountRequest -ProfileId $a.ProfileId -Path '/v1.0/messages'} 'graph_request_failed'; Assert ([AccountGraphHandler]::ApiCalls -eq 1); Assert (-not [AccountGraphHandler]::Redirects)}
    Test '403 is not retried' {$a=Account; [AccountGraphHandler]::ApiStatus=403; Reject {Invoke-GraphAccountRequest -ProfileId $a.ProfileId -Path '/v1.0/messages'} 'graph_forbidden'; Assert ([AccountGraphHandler]::ApiCalls -eq 1); Assert ($state.BrowserCalls -eq 0)}
    Test 'POST 401 is not replayed' {$a=Account; [AccountGraphHandler]::ApiStatus=401; Reject {Invoke-GraphAccountRequest -ProfileId $a.ProfileId -Path '/v1.0/messages' -Method POST -Body '{"test":true}'} 'graph_unauthorized'; Assert ([AccountGraphHandler]::ApiCalls -eq 1); Assert ($state.BrowserCalls -eq 0)}
    Test 'GET 401 with unchanged token does not replay' {$a=Account; [AccountGraphHandler]::ApiStatus=401; Reject {Invoke-GraphAccountRequest -ProfileId $a.ProfileId -Path '/v1.0/messages'} 'interaction_required'; Assert ([AccountGraphHandler]::ApiCalls -eq 1); Assert ($state.BrowserCalls -eq 1)}
    Test 'GET 401 with new token is replayed at most once' {$a=Account; $state.Raw=Jwt @{exp=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()+7200}; [AccountGraphHandler]::ApiStatus=401; Reject {Invoke-GraphAccountRequest -ProfileId $a.ProfileId -Path '/v1.0/messages'} 'graph_unauthorized'; Assert ([AccountGraphHandler]::ApiCalls -eq 2); Assert ($state.BrowserCalls -eq 1)}
    Test 'CacheOnly 401 never opens or reads browser' {$a=Account; [AccountGraphHandler]::ApiStatus=401; Reject {Invoke-GraphAccountRequest -ProfileId $a.ProfileId -Path '/v1.0/messages' -CacheOnly} 'graph_unauthorized'; Assert ($state.BrowserCalls -eq 0)}
    Test 'Bad JSON body fails before network' {Reject {Invoke-GraphAccountRequest -ProfileId ([guid]::NewGuid()) -Path '/v1.0/messages' -Method POST -Body '{invalid'} 'invalid_request_body'; Assert ([AccountGraphHandler]::Calls -eq 0)}
    Test 'Rejected bearer is removed from memory and protected cache' {$a=Account -Persist; [AccountGraphHandler]::ApiStatus=401; Reject {Invoke-GraphAccountRequest -ProfileId $a.ProfileId -Path '/v1.0/messages' -CacheOnly} 'graph_unauthorized'; Assert (-not (Test-Path (CachePath $a))); Assert ((Get-GraphAccountStatus $a.ProfileId).Status -eq 'not_connected')}
    Test 'Expiry overrides a recent in-memory verification' {$a=Account; & $module {@($script:TokenCache.Values)[0].ExpiresOn=[DateTimeOffset]::UtcNow.AddSeconds(90)}; Reject {Get-GraphAccountToken -ProfileId $a.ProfileId -CacheOnly} 'interaction_required'; Assert ($state.BrowserCalls -eq 0)}
    Test 'Exclusive profile file lock blocks another writer with bounded timeout' {$a=Account; $path=Join-Path $testRoot ($a.ProfileId+'.lock'); $lock=[IO.File]::Open($path,'OpenOrCreate','ReadWrite','None'); try {Reject {Set-GraphAccount -ProfileId $a.ProfileId -Name 'Denied'} 'profile_busy'} finally {$lock.Dispose()}; Assert ((Get-GraphAccount $a.ProfileId).Name -eq 'Offline profile')}
    Test 'Atomic write failure preserves old file and removes temporary' {$path=Join-Path $testRoot 'atomic.bin'; [IO.File]::WriteAllBytes($path,[byte[]](1,2,3)); $lock=[IO.File]::Open($path,'Open','Read','None'); try {Reject {& $module {param($p) Write-GETAtomic $p ([byte[]](4,5,6))} $path} ''} finally {$lock.Dispose()}; Assert (([IO.File]::ReadAllBytes($path) -join ',') -eq '1,2,3'); Assert (@(Get-ChildItem $testRoot -Filter '*.tmp' -Force).Count -eq 0)}
} finally {
    Clear-GraphExplorerToken; Clear-GraphAccountDiscovery; Remove-Module $module -Force
    $env:GRAPH_TOKEN_MANAGER_HOME=$priorHome
    $resolved=[IO.Path]::GetFullPath($testRoot); $tempRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if ($resolved.StartsWith($tempRoot,[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($resolved).StartsWith('GraphExplorerTokenTests-')) {Remove-Item -LiteralPath $resolved -Recurse -Force}
}
Write-Host "Accounts: $script:passed passed, $script:failed failed. Real Windows DPAPI; synthetic tokens and HTTP."
if ($script:failed) {exit 1}
