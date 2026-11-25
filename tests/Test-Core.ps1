#requires -Version 7.4
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$module = Import-Module (Join-Path $PSScriptRoot '../src/GraphExplorerToken/GraphExplorerToken.psd1') -Force -PassThru
$script:passed=0; $script:failed=0
$state=@{Calls=0;Fail=$false;BrowserCalls=0}
& $module {
    param($State)
    $script:TestState=$State
    function script:Invoke-GETIdentityCheck($Token,$Profile) {
        $script:TestState.Calls++
        if ($script:TestState.Fail) { throw 'graph_unauthorized' }
    }
    function script:Invoke-GETBrowserWorker { param([switch]$AllowInteraction,[int]$TimeoutSeconds)
        $script:TestState.BrowserCalls++; throw 'offline_browser_forbidden'
    }
} $state
$tenant='11111111-1111-4111-8111-111111111111'
$account='22222222-2222-4222-8222-222222222222'
$other='33333333-3333-4333-8333-333333333333'
function Assert($Condition,[string]$Message='assertion_failed') { if (-not $Condition) { throw $Message } }
function Reject([scriptblock]$Action,[string]$Code) {
    $caught=$null
    try { & $Action | Out-Null } catch { $caught=$_ }
    Assert ($null -ne $caught) 'expected_failure'
    if ($Code) { Assert ($caught.Exception.Message -eq $Code) ('wrong_code_expected_'+$Code) }
}
function B64([string]$Text) { [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Text)).TrimEnd('=').Replace('+','-').Replace('/','_') }
function Jwt([hashtable]$Changes=@{},[string[]]$Omit=@(),[string]$Json) {
    $now=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $claims=@{aud='00000003-0000-0000-c000-000000000000';tid=$tenant;oid=$account;scp='User.Read Mail.Read';exp=$now+3600;nbf=$now-60;canary='OFFLINE_SECRET_CANARY';jti=[guid]::NewGuid().ToString()}
    foreach ($key in $Changes.Keys) { $claims[$key]=$Changes[$key] }
    foreach ($key in $Omit) { $claims.Remove($key) }
    if (-not $Json) { $Json=$claims | ConvertTo-Json -Compress }
    (B64 '{"alg":"RS256","typ":"JWT"}')+'.'+(B64 $Json)+'.'+(B64 'offline-only-invalid-signature')
}
function Profile([string]$Oid=$account,[string[]]$Scopes=@('User.Read')) { New-GraphExplorerProfile -TenantId $tenant -AccountObjectId $Oid -RequiredScopes $Scopes }
function Connect-Test($Profile,[string]$Raw) {
    $secure=ConvertTo-SecureString $Raw -AsPlainText -Force
    try { Connect-GraphExplorerToken -Profile $Profile -Token $secure -Force } finally { $secure.Dispose() }
}
function Test([string]$Name,[scriptblock]$Action) {
    Clear-GraphExplorerToken; $state.Calls=0; $state.Fail=$false; $state.BrowserCalls=0
    try { & $Action | Out-Null; Assert ($state.BrowserCalls -eq 0); $script:passed++; Write-Host "PASS $Name" }
    catch { $script:failed++; Write-Host "FAIL $Name ($($_.Exception.GetType().Name))" }
}
function Preflight([string]$Raw,[string]$Code,$Profile=(Profile)) {
    Reject { Connect-Test $Profile $Raw } $Code
    Assert ($state.Calls -eq 0) 'unexpected_http'
    Assert ((& $module {$script:TokenCache.Count}) -eq 0) 'unexpected_cache'
}
try {
    Test 'Reject empty identities' { Reject {New-GraphExplorerProfile -TenantId ([guid]::Empty) -AccountObjectId $account} 'invalid_profile' }
    Test 'Validate margin range' { Reject {New-GraphExplorerProfile -TenantId $tenant -AccountObjectId $account -MinimumValiditySeconds 29} }
    Test 'Normalize and require User.Read' { $p=Profile $account @('Mail.Read','Mail.Read'); Assert (($p.RequiredScopes -join ' ') -eq 'Mail.Read User.Read') }
    Test 'Reject malformed scope' { Reject {Profile $account @('Mail.Read secret')} 'invalid_profile' }
    Test 'Connect and return safe metadata' {
        $p=Profile; $info=Connect-Test $p (Jwt)
        Assert ($info.Status -eq 'ready'); Assert ($state.Calls -eq 1)
        Assert ('Token' -notin $info.PSObject.Properties.Name)
    }
    Test 'Wrong tenant before HTTP' {Preflight (Jwt @{tid=$other}) 'wrong_tenant'}
    Test 'Wrong account before HTTP' {Preflight (Jwt @{oid=$other}) 'wrong_account'}
    Test 'Wrong audience before HTTP' {Preflight (Jwt @{aud='https://example.invalid'}) 'wrong_audience'}
    Test 'Exact scope matching' {Preflight (Jwt @{scp='User.ReadBasic.All'}) 'required_scopes_missing'}
    Test 'Require every scope' {Preflight (Jwt) 'required_scopes_missing' (Profile $account @('Calendars.Read'))}
    Test 'Roles cannot replace delegated scopes' {Preflight (Jwt @{roles=@('User.Read.All')} @('scp')) ''}
    Test 'Expired token' {Preflight (Jwt @{exp=1}) 'token_expired'}
    Test 'Minimum validity margin' {Preflight (Jwt @{exp=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()+60}) 'token_expired'}
    Test 'Future nbf rejected' {Preflight (Jwt @{nbf=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()+1800}) 'token_not_yet_valid'}
    Test 'Opaque token rejected' {Preflight 'opaque-offline-token' 'unsupported_token_format'}
    Test 'Oversized token rejected' {$p=Profile; Reject {& $module {param($p) Read-GETClaims ('a'*65537) $p} $p} 'invalid_token'}
    Test 'Malformed payload rejected' {Preflight (Jwt -Json '{invalid') 'invalid_token'}
    Test 'Array payload rejected' {Preflight (Jwt -Json '[1,2]') 'invalid_token'}
    Test 'Duplicate claims rejected' {Preflight (Jwt -Json '{"exp":1,"exp":2}') 'invalid_token'}
    Test 'Non-numeric expiry rejected' {Preflight (Jwt @{exp='123'}) 'invalid_token'}
    Test 'Out of range expiry rejected' {Preflight (Jwt @{exp=[long]::MaxValue}) 'invalid_token'}
    Test 'Graph failure prevents cache' {
        $p=Profile; $state.Fail=$true; Reject {Connect-Test $p (Jwt)} 'graph_unauthorized'
        Assert ($state.Calls -eq 1); Assert ((Get-GraphExplorerTokenInfo $p).Status -eq 'not_connected')
    }
    Test 'Identity isolation' {
        $a=Profile; $b=Profile $other; Connect-Test $a (Jwt)
        Assert ((Get-GraphExplorerTokenInfo $b).Status -eq 'not_connected')
        Connect-Test $b (Jwt @{oid=$other}); Assert ((& $module {$script:TokenCache.Count}) -eq 2)
    }
    Test 'Scope isolation' {
        $a=Profile; $b=Profile $account @('Mail.Read'); Connect-Test $a (Jwt)
        Assert ((Get-GraphExplorerTokenInfo $b).Status -eq 'not_connected')
    }
    Test 'Profile mutation cannot modify cached identity' {
        $p=Profile; Connect-Test $p (Jwt); $p.AccountObjectId=$other
        Assert ((Get-GraphExplorerTokenInfo (Profile)).Status -eq 'ready')
        Assert ((Get-GraphExplorerTokenInfo $p).Status -eq 'not_connected')
    }
    Test 'Returned SecureString is an independent read-only copy' {
        $p=Profile; Connect-Test $p (Jwt); $a=Get-GraphExplorerToken $p; $a.Dispose()
        $b=Get-GraphExplorerToken $p
        try { Assert ($b.Length -gt 0); Assert ($b.IsReadOnly()) } finally {$b.Dispose()}
    }
    Test 'Metadata scope array cannot mutate cache' {
        $p=Profile; Connect-Test $p (Jwt); $info=Get-GraphExplorerTokenInfo $p; $info.GrantedScopes[0]='Injected'
        Assert ('Injected' -notin (Get-GraphExplorerTokenInfo $p).GrantedScopes)
    }
    Test 'Expiry evicts and disposes token' {
        $p=Profile; Connect-Test $p (Jwt)
        $owned=& $module {$entry=@($script:TokenCache.Values)[0]; $entry.ExpiresOn=[DateTimeOffset]::UtcNow.AddSeconds(5); $entry.Token}
        Assert ((Get-GraphExplorerTokenInfo $p).Status -eq 'expired')
        Reject {$owned.Copy()}; Reject {Get-GraphExplorerToken $p} 'token_not_connected'
    }
    Test 'Recent cache hit avoids browser and HTTP' {
        $p=Profile; Connect-Test $p (Jwt); Connect-GraphExplorerToken -Profile $p
        Assert ($state.Calls -eq 1)
    }
    Test 'Failed reconnect removes previous token' {
        $p=Profile; Connect-Test $p (Jwt); $state.Fail=$true
        Reject {Connect-Test $p (Jwt)} 'graph_unauthorized'
        Assert ((Get-GraphExplorerTokenInfo $p).Status -eq 'not_connected')
    }
    Test 'Failed profile B preserves A' {
        $a=Profile; $b=Profile $other; Connect-Test $a (Jwt); $state.Fail=$true
        Reject {Connect-Test $b (Jwt @{oid=$other})} 'graph_unauthorized'
        Assert ((Get-GraphExplorerTokenInfo $a).Status -eq 'ready')
    }
    Test 'Targeted and global clear' {
        $a=Profile; $b=Profile $other; Connect-Test $a (Jwt); Connect-Test $b (Jwt @{oid=$other})
        Clear-GraphExplorerToken $a; Assert ((Get-GraphExplorerTokenInfo $b).Status -eq 'ready')
        Clear-GraphExplorerToken; Assert ((& $module {$script:TokenCache.Count}) -eq 0)
    }
    Test 'Output and errors never contain token canary' {
        $p=Profile; $raw=Jwt; $bad=Jwt @{tid=$other}
        $records=@(& { Connect-Test $p $raw; Get-GraphExplorerTokenInfo $p; try {Connect-Test $p $bad} catch {$_} } *>&1)
        $safeRecords=@(foreach ($record in $records) {
            if ($record -is [Management.Automation.ErrorRecord]) {
                $record.ToString(); $record.Exception.ToString(); $record.ScriptStackTrace
            } else { $record | ConvertTo-Json -Depth 4 -Compress }
        })
        $serialized=$safeRecords -join "`n"
        foreach ($secret in @($raw,$bad,$raw.Split('.')[1],'OFFLINE_SECRET_CANARY')) {Assert (-not $serialized.Contains($secret))}
    }
} finally { Clear-GraphExplorerToken; Remove-Module -ModuleInfo $module -Force }
Write-Host "Core: $script:passed passed, $script:failed failed. Synthetic tokens only."
if ($script:failed) {exit 1}
