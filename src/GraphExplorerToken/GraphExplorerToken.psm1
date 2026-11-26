Set-StrictMode -Version Latest
$script:TokenCache = @{}
$script:KnownErrors = @('invalid_profile','invalid_token','unsupported_token_format','token_expired','token_not_yet_valid','wrong_audience','wrong_tenant','wrong_account','required_scopes_missing','graph_unauthorized','graph_forbidden','graph_throttled','graph_unavailable','graph_identity_mismatch','browser_timeout','browser_confirmation_required','browser_unavailable','browser_origin_not_verified','graph_explorer_tab_not_found','ambiguous_explorer_windows','token_not_visible','ambiguous_token_controls','desktop_in_use','control_not_actionable','interaction_required','unsupported_platform','token_not_connected','token_worker_failed','private_worker_required','operation_failed')

function New-GraphExplorerProfile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][guid]$TenantId,
        [Parameter(Mandatory)][guid]$AccountObjectId,
        [string[]]$RequiredScopes = @('User.Read'),
        [ValidateRange(30,600)][int]$MinimumValiditySeconds = 180
    )
    if ($TenantId -eq [guid]::Empty -or $AccountObjectId -eq [guid]::Empty) { throw 'invalid_profile' }
    foreach ($scope in $RequiredScopes) {
        if ($scope -cnotmatch '^[A-Za-z][A-Za-z0-9.-]{0,119}$') { throw 'invalid_profile' }
    }
    [pscustomobject]@{
        PSTypeName = 'GraphExplorerToken.Profile'
        TenantId = $TenantId.ToString()
        AccountObjectId = $AccountObjectId.ToString()
        RequiredScopes = [string[]](@('User.Read') + $RequiredScopes | Sort-Object -Unique -CaseSensitive)
        MinimumValiditySeconds = $MinimumValiditySeconds
    }
}

function Resolve-GETProfile($Profile) {
    try {
        New-GraphExplorerProfile -TenantId $Profile.TenantId -AccountObjectId $Profile.AccountObjectId -RequiredScopes $Profile.RequiredScopes -MinimumValiditySeconds $Profile.MinimumValiditySeconds
    } catch { throw 'invalid_profile' }
}

function Get-GETProfileKey($Profile) {
    $Profile.TenantId + '|' + $Profile.AccountObjectId + '|' + ($Profile.RequiredScopes -join ' ') + '|' + $Profile.MinimumValiditySeconds
}

function ConvertFrom-GETSecureString([Security.SecureString]$Value) {
    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Value)
    try { [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
}

function Read-GETClaims([string]$Token, $Profile) {
    if ([string]::IsNullOrWhiteSpace($Token) -or $Token.Length -gt 65536) { throw 'invalid_token' }
    if ($Token -cnotmatch '^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$') { throw 'unsupported_token_format' }
    try {
        $payload = $Token.Split('.')[1].Replace('-','+').Replace('_','/')
        $payload = $payload.PadRight($payload.Length + ((4 - $payload.Length % 4) % 4),'=')
        $json = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload))
        $options = [Text.Json.JsonDocumentOptions]::new(); $options.MaxDepth = 16
        $document = [Text.Json.JsonDocument]::Parse($json,$options)
        try {
            if ($document.RootElement.ValueKind -ne [Text.Json.JsonValueKind]::Object) { throw 'invalid_token' }
            $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
            foreach ($property in $document.RootElement.EnumerateObject()) {
                if (-not $names.Add($property.Name)) { throw 'invalid_token' }
            }
        } finally { $document.Dispose() }
        $claims = $json | ConvertFrom-Json -AsHashtable -ErrorAction Stop
        if ($claims -isnot [System.Collections.IDictionary]) { throw 'invalid_token' }
        if (-not $claims.Contains('exp') -or $claims.exp -isnot [long] -and $claims.exp -isnot [int]) { throw 'invalid_token' }
        $expires = [DateTimeOffset]::FromUnixTimeSeconds([long]$claims.exp)
    } catch { throw 'invalid_token' }
    $now = [DateTimeOffset]::UtcNow
    if ($expires -le $now.AddSeconds($Profile.MinimumValiditySeconds)) { throw 'token_expired' }
    if ($claims.Contains('nbf')) {
        if ($claims.nbf -isnot [long] -and $claims.nbf -isnot [int]) { throw 'invalid_token' }
        if ([long]$claims.nbf -gt $now.ToUnixTimeSeconds() + 60) { throw 'token_not_yet_valid' }
    }
    if ($claims.aud -isnot [string] -or $claims.aud -cnotin @('00000003-0000-0000-c000-000000000000','https://graph.microsoft.com','https://graph.microsoft.com/')) { throw 'wrong_audience' }
    $tenant = [guid]::Empty; $account = [guid]::Empty
    if (-not [guid]::TryParse([string]$claims.tid,[ref]$tenant) -or $tenant.ToString() -cne $Profile.TenantId) { throw 'wrong_tenant' }
    if (-not [guid]::TryParse([string]$claims.oid,[ref]$account) -or $account.ToString() -cne $Profile.AccountObjectId) { throw 'wrong_account' }
    if ($claims.scp -isnot [string]) { throw 'required_scopes_missing' }
    $scopes = [string[]]($claims.scp.Split(' ',[StringSplitOptions]::RemoveEmptyEntries) | Sort-Object -Unique -CaseSensitive)
    foreach ($scope in $Profile.RequiredScopes) { if ($scope -cnotin $scopes) { throw 'required_scopes_missing' } }
    # Claims are only preliminary metadata. Graph validates the actual credential below.
    [pscustomobject]@{ ExpiresOn = $expires; GrantedScopes = $scopes }
}

function New-GETHttpHandler { [Net.Http.HttpClientHandler]::new() }

function Invoke-GETIdentityCheck([string]$Token, $Profile) {
    $handler = New-GETHttpHandler
    $handler.AllowAutoRedirect = $false
    $client = [Net.Http.HttpClient]::new($handler)
    $client.Timeout = [TimeSpan]::FromSeconds(15)
    $request = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Get,'https://graph.microsoft.com/v1.0/me?$select=id')
    $response = $null
    try {
        $request.Headers.Authorization = [Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer',$Token)
        try { $response = $client.SendAsync($request).GetAwaiter().GetResult() } catch { throw 'graph_unavailable' }
        switch ([int]$response.StatusCode) {
            200 { }
            401 { throw 'graph_unauthorized' }
            403 { throw 'graph_forbidden' }
            429 { throw 'graph_throttled' }
            default { throw 'graph_unavailable' }
        }
        try {
            $body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult() | ConvertFrom-Json -AsHashtable
            $id = [guid]::Empty
            if (-not [guid]::TryParse([string]$body.id,[ref]$id) -or $id.ToString() -cne $Profile.AccountObjectId) { throw 'graph_identity_mismatch' }
        } catch { throw 'graph_identity_mismatch' }
    } finally {
        if ($response) { $response.Dispose() }
        $request.Dispose(); $client.Dispose()
    }
}

function Invoke-GETBrowserWorker([switch]$AllowInteraction,[int]$TimeoutSeconds=30,[long]$WindowHandle=0,[ValidateSet('Read','List','Refresh','SignIn','SelectAccount')][string]$Action='Read',[string]$AccountUsername) {
    if (-not $IsWindows) { throw 'unsupported_platform' }
    $start = [Diagnostics.ProcessStartInfo]::new((Join-Path $PSHOME 'pwsh.exe'))
    $start.UseShellExecute = $false; $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true; $start.RedirectStandardError = $true
    $worker = Join-Path $PSScriptRoot '../../scripts/Read-BrowserToken.ps1'
    foreach ($arg in @('-NoLogo','-NoProfile','-NonInteractive','-File',$worker,'-TimeoutSeconds',[string]$TimeoutSeconds)) { $start.ArgumentList.Add($arg) }
    if ($AllowInteraction) { $start.ArgumentList.Add('-AllowInteraction') }
    foreach ($arg in @('-WindowHandle',[string]$WindowHandle,'-Action',$Action)) { $start.ArgumentList.Add($arg) }
    if ($AccountUsername) { $start.ArgumentList.Add('-AccountUsername'); $start.ArgumentList.Add($AccountUsername) }
    $start.Environment['GET_PRIVATE_WORKER'] = '1'
    $child = $null
    try {
        $child = [Diagnostics.Process]::Start($start)
        $output = $child.StandardOutput.ReadToEndAsync(); $errors = $child.StandardError.ReadToEndAsync()
        if (-not $child.WaitForExit(($TimeoutSeconds + 2) * 1000)) {
            $child.Kill($true); $child.WaitForExit(); throw 'browser_timeout'
        }
        try { $value = $output.GetAwaiter().GetResult() | ConvertFrom-Json -AsHashtable } catch { throw 'token_worker_failed' }
        if ($child.ExitCode -ne 0) {
            if ($value.code -cin $script:KnownErrors) { throw $value.code }
            throw 'token_worker_failed'
        }
        if ($Action -eq 'List') { return @($value.windows) }
        if ($Action -in @('SignIn','SelectAccount')) { return [pscustomobject]$value.result }
        if (-not $value.access_token -or $value.access_token -isnot [string]) { throw 'token_worker_failed' }
        return $value.access_token
    } finally { if ($child) { $child.Dispose() }; $output = $null; $errors = $null; $value = $null }
}

function Remove-GETCacheEntry([string]$Key) {
    if ($script:TokenCache.ContainsKey($Key)) {
        $script:TokenCache[$Key].Token.Dispose()
        $script:TokenCache.Remove($Key)
    }
}

function Connect-GraphExplorerToken {
    [CmdletBinding(DefaultParameterSetName='Browser')]
    param(
        [Parameter(Mandatory)]$Profile,
        [Parameter(Mandatory,ParameterSetName='Manual')][Security.SecureString]$Token,
        [Parameter(ParameterSetName='Browser')][switch]$AllowInteraction,
        [Parameter(ParameterSetName='Browser')][ValidateRange(5,120)][int]$TimeoutSeconds = 30,
        [switch]$Force
    )
    $plain = $null; $key = $null
    try {
        $resolved = Resolve-GETProfile $Profile
        $key = Get-GETProfileKey $resolved
        if (-not $Force -and $PSCmdlet.ParameterSetName -eq 'Browser' -and $script:TokenCache.ContainsKey($key)) {
            $entry = $script:TokenCache[$key]
            if ($entry.ExpiresOn -gt [DateTimeOffset]::UtcNow.AddSeconds($resolved.MinimumValiditySeconds) -and $entry.VerifiedAt -gt [DateTimeOffset]::UtcNow.AddMinutes(-5)) {
                return Get-GraphExplorerTokenInfo -Profile $resolved
            }
        }
        Remove-GETCacheEntry $key
        $source = if ($PSCmdlet.ParameterSetName -eq 'Manual') { 'manual_secure_input' } else { 'visible_graph_explorer' }
        $plain = if ($PSCmdlet.ParameterSetName -eq 'Manual') { ConvertFrom-GETSecureString $Token } else { Invoke-GETBrowserWorker -AllowInteraction:$AllowInteraction -TimeoutSeconds $TimeoutSeconds }
        $metadata = Read-GETClaims $plain $resolved
        Invoke-GETIdentityCheck $plain $resolved
        # Validate time again after the HTTP call, including the configured margin.
        $metadata = Read-GETClaims $plain $resolved
        if ($script:TokenCache.Count -ge 10) {
            $oldest = $script:TokenCache.GetEnumerator() | Sort-Object { $_.Value.VerifiedAt } | Select-Object -First 1
            Remove-GETCacheEntry $oldest.Key
        }
        $script:TokenCache[$key] = [pscustomobject]@{
            Token = ConvertTo-SecureString -String $plain -AsPlainText -Force
            Profile = $resolved
            ExpiresOn = $metadata.ExpiresOn
            VerifiedAt = [DateTimeOffset]::UtcNow
            GrantedScopes = $metadata.GrantedScopes
            Source = $source
        }
        Get-GraphExplorerTokenInfo -Profile $resolved
    } catch {
        if ($key) { Remove-GETCacheEntry $key }
        $code = $_.Exception.Message
        if ($code -cnotin $script:KnownErrors) { $code = 'operation_failed' }
        # Construct a fresh error without retaining a credential-bearing inner exception.
        $record = [Management.Automation.ErrorRecord]::new([InvalidOperationException]::new($code),$code,[Management.Automation.ErrorCategory]::InvalidOperation,$null)
        $PSCmdlet.ThrowTerminatingError($record)
    } finally { $plain = $null }
}

function Get-GraphExplorerTokenInfo {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Profile)
    $resolved = Resolve-GETProfile $Profile
    $key = Get-GETProfileKey $resolved
    if (-not $script:TokenCache.ContainsKey($key)) { return [pscustomobject]@{ Status = 'not_connected' } }
    $entry = $script:TokenCache[$key]
    if ($entry.ExpiresOn -le [DateTimeOffset]::UtcNow.AddSeconds($resolved.MinimumValiditySeconds)) {
        Remove-GETCacheEntry $key
        return [pscustomobject]@{ Status = 'expired' }
    }
    [pscustomobject]@{
        Status = 'ready'
        TenantId = $resolved.TenantId
        AccountObjectId = $resolved.AccountObjectId
        ExpiresOn = $entry.ExpiresOn.ToString('o')
        RemainingSeconds = [int][Math]::Floor(($entry.ExpiresOn - [DateTimeOffset]::UtcNow).TotalSeconds)
        VerifiedAt = $entry.VerifiedAt.ToString('o')
        GrantedScopes = [string[]]$entry.GrantedScopes.Clone()
        Source = $entry.Source
        Verification = 'graph_me'
    }
}

function Get-GraphExplorerToken {
    [CmdletBinding()]
    [OutputType([Security.SecureString])]
    param([Parameter(Mandatory)]$Profile)
    $resolved = Resolve-GETProfile $Profile
    $info = Get-GraphExplorerTokenInfo $resolved
    if ($info.Status -ne 'ready') { throw 'token_not_connected' }
    $copy = $script:TokenCache[(Get-GETProfileKey $resolved)].Token.Copy()
    $copy.MakeReadOnly()
    return $copy
}

function Clear-GraphExplorerToken {
    [CmdletBinding()]
    param($Profile)
    if ($null -ne $Profile) { Remove-GETCacheEntry (Get-GETProfileKey (Resolve-GETProfile $Profile)) }
    else { foreach ($key in @($script:TokenCache.Keys)) { Remove-GETCacheEntry $key } }
}

function Test-GraphExplorerEnvironment {
    [CmdletBinding()]
    param()
    $edge = if ($IsWindows) { @(Get-Process -Name msedge -ErrorAction SilentlyContinue).Count -gt 0 } else { $false }
    [pscustomobject]@{
        Version = '2.0.0'; PowerShellVersion = $PSVersionTable.PSVersion.ToString()
        Windows = [bool]$IsWindows; InteractiveSession = [Environment]::UserInteractive
        EdgeRunning = $edge; BrowserSupported = [bool]($IsWindows -and [Environment]::UserInteractive)
        TokenStorage = 'process_memory_or_opt_in_windows_dpapi'; RequiredBrowser = 'Microsoft Edge (Italian or English UI)'
    }
}

function Open-GraphExplorer {
    [CmdletBinding()]
    param([switch]$InPrivate)
    if (-not $IsWindows) { throw 'unsupported_platform' }
    # A dedicated interactive window keeps Graph Explorer separate from other work.
    $edge = @("${env:ProgramFiles(x86)}/Microsoft/Edge/Application/msedge.exe", "$env:ProgramFiles/Microsoft/Edge/Application/msedge.exe", "$env:LOCALAPPDATA/Microsoft/Edge/Application/msedge.exe") | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if (-not $edge) { throw 'browser_unavailable' }
    $arguments=@('--new-window','https://developer.microsoft.com/en-us/graph/graph-explorer')
    if ($InPrivate) {$arguments=@('--inprivate')+$arguments}
    Start-Process -FilePath $edge -ArgumentList $arguments
}

. (Join-Path $PSScriptRoot 'Private/Accounts.ps1')
$ExecutionContext.SessionState.Module.OnRemove = { foreach ($entry in $script:TokenCache.Values) { $entry.Token.Dispose() }; $script:TokenCache.Clear(); foreach ($entry in $script:Discoveries.Values) { $entry.Token.Dispose() }; $script:Discoveries.Clear() }
Export-ModuleMember -Function New-GraphExplorerProfile,Connect-GraphExplorerToken,Get-GraphExplorerToken,Get-GraphExplorerTokenInfo,Clear-GraphExplorerToken,Test-GraphExplorerEnvironment,Open-GraphExplorer,Get-GraphExplorerWindow,Start-GraphExplorerSignIn,Select-GraphSignInAccount,New-GraphAccountDiscovery,Clear-GraphAccountDiscovery,Save-GraphAccount,Get-GraphAccount,Set-GraphAccount,Remove-GraphAccount,Clear-GraphAccountToken,Get-GraphAccountToken,Get-GraphAccountStatus,Invoke-GraphAccountRequest
