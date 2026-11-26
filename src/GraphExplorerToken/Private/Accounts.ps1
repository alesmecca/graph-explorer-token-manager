$script:Discoveries = @{}
$script:KnownErrors += @('profile_not_found','profile_store_invalid','cache_corrupt','cache_unavailable','profile_busy','discovery_expired','invalid_graph_path','graph_request_failed','graph_response_too_large','invalid_request_body')

function Stop-GETAccountError($Failure) {
    $code = $Failure.Exception.Message
    if ($code -cnotin $script:KnownErrors) { $code = 'operation_failed' }
    throw [InvalidOperationException]::new($code)
}

function Get-GETStateRoot {
    if (-not $IsWindows) { throw 'unsupported_platform' }
    $path = if ($env:GRAPH_TOKEN_MANAGER_HOME) { $env:GRAPH_TOKEN_MANAGER_HOME } else { Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'GraphExplorerTokenManager' }
    [IO.Path]::GetFullPath($path)
}

function Get-GETAccountPath([guid]$ProfileId,[string]$Extension='json') {
    if ($ProfileId -eq [guid]::Empty) { throw 'invalid_profile' }
    Join-Path (Get-GETStateRoot) ($ProfileId.ToString() + '.' + $Extension)
}

function Invoke-GETAccountLock([guid]$ProfileId,[scriptblock]$Action) {
    $path = Get-GETAccountPath $ProfileId 'lock'
    $null = [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path))
    $clock = [Diagnostics.Stopwatch]::StartNew(); $lock = $null
    try {
        # File locks also synchronize tasks running in another Windows session.
        while (-not $lock) {
            try { $lock = [IO.File]::Open($path,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None) }
            catch [IO.IOException] { if ($clock.ElapsedMilliseconds -ge 5000) {throw 'profile_busy'}; Start-Sleep -Milliseconds 50 }
        }
        & $Action
    } finally { if ($lock) {$lock.Dispose()} }
}

function Write-GETAtomic([string]$Path,[byte[]]$Bytes) {
    $directory = [IO.Path]::GetDirectoryName($Path)
    $null = [IO.Directory]::CreateDirectory($directory)
    $temp = Join-Path $directory ('.' + [guid]::NewGuid().ToString() + '.tmp')
    try {
        $stream = [IO.FileStream]::new($temp,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        try { $stream.Write($Bytes,0,$Bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
        # Same-volume replace: readers see either the old or complete new file.
        [IO.File]::Move($temp,$Path,$true)
    } finally { if ([IO.File]::Exists($temp)) { [IO.File]::Delete($temp) } }
}

function Read-GETBoundedFile([string]$Path,[int]$Limit) {
    $stream = [IO.FileStream]::new($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
    try {
        if ($stream.Length -le 0 -or $stream.Length -gt $Limit) { throw 'profile_store_invalid' }
        $bytes = [byte[]]::new([int]$stream.Length)
        $stream.ReadExactly($bytes,0,$bytes.Length)
        return ,$bytes
    } finally { $stream.Dispose() }
}

function Resolve-GETAccount($Data) {
    try {
        if ($Data.SchemaVersion -ne 2) { throw 'invalid_profile' }
        $id = [guid]$Data.ProfileId
        if ($id -eq [guid]::Empty) { throw 'invalid_profile' }
        $profile = Resolve-GETProfile $Data
        if ($Data.Name -isnot [string] -or [string]::IsNullOrWhiteSpace($Data.Name) -or $Data.Name.Length -gt 120 -or $Data.Name -match '[\x00-\x1f]') { throw 'invalid_profile' }
        if ($Data.PersistToken -isnot [bool] -or $Data.AllowRefresh -isnot [bool]) { throw 'invalid_profile' }
        [pscustomobject]@{
            SchemaVersion = 2; ProfileId = $id.ToString(); Name = $Data.Name.Trim()
            DisplayName = ([string]$Data.DisplayName -replace '[\x00-\x1f]','').Substring(0,[Math]::Min(200,([string]$Data.DisplayName -replace '[\x00-\x1f]','').Length))
            UserPrincipalName = ([string]$Data.UserPrincipalName -replace '[\x00-\x1f]','').Substring(0,[Math]::Min(320,([string]$Data.UserPrincipalName -replace '[\x00-\x1f]','').Length))
            TenantId = $profile.TenantId; AccountObjectId = $profile.AccountObjectId
            RequiredScopes = $profile.RequiredScopes; MinimumValiditySeconds = $profile.MinimumValiditySeconds
            WindowHandle = [long]$Data.WindowHandle
            PersistToken = $Data.PersistToken; AllowRefresh = $Data.AllowRefresh
        }
    } catch { throw 'invalid_profile' }
}

function Read-GETAccount([guid]$ProfileId) {
    $path = Get-GETAccountPath $ProfileId
    if (-not [IO.File]::Exists($path)) { throw 'profile_not_found' }
    try {
        $data = [Text.Encoding]::UTF8.GetString((Read-GETBoundedFile $path 16384)) | ConvertFrom-Json -AsHashtable
        $account = Resolve-GETAccount $data
        if ($account.ProfileId -ne $ProfileId.ToString()) { throw 'invalid_profile' }
        $account
    } catch { throw 'profile_store_invalid' }
}

function Write-GETAccount($Account) {
    $safe = Resolve-GETAccount $Account
    Write-GETAtomic (Get-GETAccountPath $safe.ProfileId) ([Text.Encoding]::UTF8.GetBytes(($safe | ConvertTo-Json -Depth 4)))
}

function Write-GETProtectedToken($Account) {
    if (-not $Account.PersistToken) { return }
    $resolved = Resolve-GETProfile $Account; $key = Get-GETProfileKey $resolved
    if ((Get-GraphExplorerTokenInfo $resolved).Status -ne 'ready') { throw 'token_not_connected' }
    $plain = $null; $bytes = $null
    try {
        $entry = $script:TokenCache[$key]
        $plain = ConvertFrom-GETSecureString $entry.Token
        $null = Read-GETClaims $plain $resolved
        $payload = @{ SchemaVersion=2; ProfileId=$Account.ProfileId; ProfileKey=$key; Token=$plain; VerifiedAtUnix=$entry.VerifiedAt.ToUnixTimeSeconds() }
        $bytes = [Text.Encoding]::UTF8.GetBytes(($payload | ConvertTo-Json -Compress))
        $entropy = [Text.Encoding]::UTF8.GetBytes('GraphExplorerTokenManager:v2:' + $Account.ProfileId)
        $protected = [Security.Cryptography.ProtectedData]::Protect($bytes,$entropy,[Security.Cryptography.DataProtectionScope]::CurrentUser)
        Write-GETAtomic (Get-GETAccountPath $Account.ProfileId 'bin') $protected
    } catch { throw 'cache_unavailable' }
    finally { if ($bytes) { [Array]::Clear($bytes,0,$bytes.Length) }; $plain=$null; $payload=$null }
}

function Read-GETProtectedToken($Account) {
    $bytes=$null; $plain=$null; $payload=$null
    try {
        $protected = Read-GETBoundedFile (Get-GETAccountPath $Account.ProfileId 'bin') 131072
        $entropy = [Text.Encoding]::UTF8.GetBytes('GraphExplorerTokenManager:v2:' + $Account.ProfileId)
        $bytes = [Security.Cryptography.ProtectedData]::Unprotect($protected,$entropy,[Security.Cryptography.DataProtectionScope]::CurrentUser)
        $payload = [Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json -AsHashtable
        $key = Get-GETProfileKey (Resolve-GETProfile $Account)
        if ($payload.SchemaVersion -ne 2 -or $payload.ProfileId -cne $Account.ProfileId -or $payload.ProfileKey -cne $key -or $payload.Token -isnot [string]) { throw 'cache_corrupt' }
        if ($payload.VerifiedAtUnix -isnot [long] -and $payload.VerifiedAtUnix -isnot [int]) { throw 'cache_corrupt' }
        $verified = [DateTimeOffset]::FromUnixTimeSeconds($payload.VerifiedAtUnix)
        if ($verified -gt [DateTimeOffset]::UtcNow.AddMinutes(1)) { throw 'cache_corrupt' }
        $plain = $payload.Token
    } catch { throw 'cache_corrupt' }
    finally { if ($bytes) { [Array]::Clear($bytes,0,$bytes.Length) } }
    try {
        $metadata = Read-GETClaims $plain (Resolve-GETProfile $Account)
        [pscustomobject]@{ Token=(ConvertTo-SecureString $plain -AsPlainText -Force); ExpiresOn=$metadata.ExpiresOn; VerifiedAt=$verified }
    } finally { $plain=$null; $payload=$null }
}

function Invoke-GETDiscoveryIdentity([string]$Token,$Profile) {
    $handler=New-GETHttpHandler; $handler.AllowAutoRedirect=$false
    $client=[Net.Http.HttpClient]::new($handler); $client.Timeout=[TimeSpan]::FromSeconds(15)
    $client.MaxResponseContentBufferSize=131072
    $request=[Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Get,'https://graph.microsoft.com/v1.0/me?$select=id,displayName,userPrincipalName')
    $response=$null
    try {
        $request.Headers.Authorization=[Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer',$Token)
        try { $response=$client.SendAsync($request).GetAwaiter().GetResult() } catch { throw 'graph_unavailable' }
        switch ([int]$response.StatusCode) { 200 {} 401 {throw 'graph_unauthorized'} 403 {throw 'graph_forbidden'} 429 {throw 'graph_throttled'} default {throw 'graph_unavailable'} }
        try {
            $body=$response.Content.ReadAsStringAsync().GetAwaiter().GetResult() | ConvertFrom-Json -AsHashtable
            if ([guid]$body.id -ne [guid]$Profile.AccountObjectId) { throw 'graph_identity_mismatch' }
            [pscustomobject]@{DisplayName=[string]$body.displayName; UserPrincipalName=[string]$body.userPrincipalName; TenantId=$Profile.TenantId; AccountObjectId=$Profile.AccountObjectId}
        } catch { throw 'graph_identity_mismatch' }
    } finally { if ($response) {$response.Dispose()}; $request.Dispose(); $client.Dispose() }
}

function Get-GraphExplorerWindow {
    [CmdletBinding()]param()
    try { Invoke-GETBrowserWorker -Action List -TimeoutSeconds 15 } catch { Stop-GETAccountError $_ }
}

function Start-GraphExplorerSignIn {
    [CmdletBinding()]param([switch]$InPrivate,[long]$WindowHandle=0)
    try {
        $before=@()
        try {$before=@(Get-GraphExplorerWindow)} catch {if ($_.Exception.Message -notin @('browser_unavailable','graph_explorer_tab_not_found')) {throw}}
        if (-not $InPrivate -and -not $WindowHandle -and $before.Count -eq 1) {$WindowHandle=$before[0].WindowHandle}
        if (-not $InPrivate -and -not $WindowHandle -and $before.Count -gt 1) {throw 'ambiguous_explorer_windows'}
        if ($InPrivate -or -not $WindowHandle) {
            Open-GraphExplorer -InPrivate:$InPrivate
            $WindowHandle=0
            for ($i=0;$i -lt 5;$i++) {
                Start-Sleep -Milliseconds 800
                $current=@(Get-GraphExplorerWindow)
                $new=@($current | Where-Object {$_.WindowHandle -notin @($before | ForEach-Object WindowHandle)})
                if ($new.Count -eq 1) {$WindowHandle=$new[0].WindowHandle; break}
                if (-not $InPrivate -and $current.Count -eq 1) {$WindowHandle=$current[0].WindowHandle; break}
            }
            if (-not $WindowHandle) {throw 'graph_explorer_tab_not_found'}
        }
        Invoke-GETBrowserWorker -Action SignIn -AllowInteraction -WindowHandle $WindowHandle -TimeoutSeconds 30
    } catch {Stop-GETAccountError $_}
}

function Select-GraphSignInAccount {
    [CmdletBinding()]param([Parameter(Mandatory)][long]$LoginWindowHandle,[Parameter(Mandatory)][string]$Username)
    try {
        if ($Username -cne '__other__' -and $Username -notmatch '^[A-Za-z0-9._%+!#-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$') {throw 'invalid_profile'}
        Invoke-GETBrowserWorker -Action SelectAccount -AllowInteraction -WindowHandle $LoginWindowHandle -AccountUsername $Username -TimeoutSeconds 15
    } catch {Stop-GETAccountError $_}
}

function Clear-GraphAccountDiscovery {
    [CmdletBinding()]param()
    foreach ($entry in $script:Discoveries.Values) { $entry.Token.Dispose() }
    $script:Discoveries.Clear()
}

function New-GraphAccountDiscovery {
    [CmdletBinding(DefaultParameterSetName='Browser')]
    param(
        [Parameter(ParameterSetName='Browser')][long]$WindowHandle=0,
        [Parameter(ParameterSetName='Browser')][switch]$AllowInteraction,
        [Parameter(Mandatory,ParameterSetName='Manual')][Security.SecureString]$Token,
        [string[]]$RequiredScopes=@('User.Read')
    )
    $plain=$null; $pending=$null
    Clear-GraphAccountDiscovery
    try {
        $plain=if ($PSCmdlet.ParameterSetName -eq 'Manual') { ConvertFrom-GETSecureString $Token } else { Invoke-GETBrowserWorker -WindowHandle $WindowHandle -AllowInteraction:$AllowInteraction }
        # Only derive an expected identity here. Read-GETClaims applies all structural checks,
        # then Graph verifies this exact bearer before any identity is offered to the user.
        try {
            if ($plain.Length -gt 65536 -or $plain -cnotmatch '^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$') { throw 'invalid_token' }
            $encoded=$plain.Split('.')[1].Replace('-','+').Replace('_','/')
            $encoded=$encoded.PadRight($encoded.Length+((4-$encoded.Length%4)%4),'=')
            $claims=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($encoded)) | ConvertFrom-Json -AsHashtable
            $profile=New-GraphExplorerProfile -TenantId $claims.tid -AccountObjectId $claims.oid -RequiredScopes $RequiredScopes
        } catch { throw 'invalid_token' }
        $metadata=Read-GETClaims $plain $profile
        $identity=Invoke-GETDiscoveryIdentity $plain $profile
        $metadata=Read-GETClaims $plain $profile
        $id=[guid]::NewGuid().ToString()
        $pending=ConvertTo-SecureString $plain -AsPlainText -Force
        $script:Discoveries[$id]=[pscustomobject]@{Token=$pending; Profile=$profile; Identity=$identity; Metadata=$metadata; WindowHandle=$WindowHandle; CreatedAt=[DateTimeOffset]::UtcNow}
        [pscustomobject]@{ DiscoveryId=$id; Identity=$identity; ExpiresOn=$metadata.ExpiresOn.ToString('o'); GrantedScopes=$metadata.GrantedScopes; ConfirmationRequired=$true }
    } catch { if ($pending) {$pending.Dispose()}; Stop-GETAccountError $_ }
    finally { $plain=$null; $claims=$null }
}

function Save-GraphAccount {
    [CmdletBinding()]param([Parameter(Mandatory)][guid]$DiscoveryId,[Parameter(Mandatory)][string]$Name,[switch]$PersistToken,[switch]$AllowRefresh)
    $plain=$null
    try {
        $id=$DiscoveryId.ToString()
        if (-not $script:Discoveries.ContainsKey($id)) { throw 'discovery_expired' }
        $entry=$script:Discoveries[$id]
        if ($entry.CreatedAt -le [DateTimeOffset]::UtcNow.AddMinutes(-5)) { Clear-GraphAccountDiscovery; throw 'discovery_expired' }
        $plain=ConvertFrom-GETSecureString $entry.Token
        $metadata=Read-GETClaims $plain $entry.Profile
        $account=Resolve-GETAccount ([pscustomobject]@{
            SchemaVersion=2; ProfileId=[guid]::NewGuid().ToString(); Name=$Name
            DisplayName=$entry.Identity.DisplayName; UserPrincipalName=$entry.Identity.UserPrincipalName
            TenantId=$entry.Profile.TenantId; AccountObjectId=$entry.Profile.AccountObjectId
            RequiredScopes=$entry.Profile.RequiredScopes; MinimumValiditySeconds=$entry.Profile.MinimumValiditySeconds
            WindowHandle=$entry.WindowHandle; PersistToken=[bool]$PersistToken; AllowRefresh=[bool]$AllowRefresh
        })
        Invoke-GETAccountLock $account.ProfileId {
            $key=Get-GETProfileKey $entry.Profile
            Remove-GETCacheEntry $key
            if ($script:TokenCache.Count -ge 10) {$oldest=$script:TokenCache.GetEnumerator() | Sort-Object {$_.Value.VerifiedAt} | Select-Object -First 1; Remove-GETCacheEntry $oldest.Key}
            $script:TokenCache[$key]=[pscustomobject]@{Token=$entry.Token.Copy(); Profile=$entry.Profile; ExpiresOn=$metadata.ExpiresOn; VerifiedAt=$entry.CreatedAt; GrantedScopes=$metadata.GrantedScopes; Source='confirmed_account'}
            try { Write-GETProtectedToken $account; Write-GETAccount $account }
            catch {
                Remove-GETCacheEntry $key
                $path=Get-GETAccountPath $account.ProfileId 'bin'; if ([IO.File]::Exists($path)) {[IO.File]::Delete($path)}
                throw
            }
        }
        Clear-GraphAccountDiscovery
        $account
    } catch { Stop-GETAccountError $_ } finally { $plain=$null }
}

function Get-GraphAccount {
    [CmdletBinding()]param([guid]$ProfileId)
    try {
        if ($PSBoundParameters.ContainsKey('ProfileId')) { Read-GETAccount $ProfileId; return }
        $root=Get-GETStateRoot
        if (-not [IO.Directory]::Exists($root)) { return }
        foreach ($file in [IO.Directory]::EnumerateFiles($root,'*.json')) {
            $id=[guid]::Empty
            if ([guid]::TryParse([IO.Path]::GetFileNameWithoutExtension($file),[ref]$id)) { Read-GETAccount $id }
        }
    } catch { Stop-GETAccountError $_ }
}

function Set-GraphAccount {
    [CmdletBinding()]param([Parameter(Mandatory)][guid]$ProfileId,[string]$Name,[bool]$PersistToken,[bool]$AllowRefresh,[long]$WindowHandle,[string[]]$RequiredScopes)
    $changes=$PSBoundParameters
    try {
        Invoke-GETAccountLock $ProfileId {
            $account=Read-GETAccount $ProfileId; $oldProfile=Resolve-GETProfile $account
            foreach ($field in @('Name','PersistToken','AllowRefresh','WindowHandle','RequiredScopes')) { if ($changes.ContainsKey($field)) { $account.$field=$changes[$field] } }
            $account=Resolve-GETAccount $account
            $scopeChange=(Get-GETProfileKey $oldProfile) -cne (Get-GETProfileKey (Resolve-GETProfile $account))
            # Write metadata first: disabling persistence is effective even if deletion fails.
            Write-GETAccount $account
            if (-not $account.PersistToken -or $scopeChange) {
                $path=Get-GETAccountPath $ProfileId 'bin'; if ([IO.File]::Exists($path)) {[IO.File]::Delete($path)}
            }
            if ($scopeChange) { Clear-GraphExplorerToken $oldProfile }
            elseif ($account.PersistToken -and (Get-GraphExplorerTokenInfo $account).Status -eq 'ready') { Write-GETProtectedToken $account }
            $account
        }
    } catch { Stop-GETAccountError $_ }
}

function Clear-GraphAccountToken {
    [CmdletBinding()]param([Parameter(Mandatory)][guid]$ProfileId)
    try { Invoke-GETAccountLock $ProfileId {
        $account=Read-GETAccount $ProfileId; Clear-GraphExplorerToken $account
        $path=Get-GETAccountPath $ProfileId 'bin'; if ([IO.File]::Exists($path)) {[IO.File]::Delete($path)}
    } } catch { Stop-GETAccountError $_ }
}

function Remove-GraphAccount {
    [CmdletBinding()]param([Parameter(Mandatory)][guid]$ProfileId)
    try { Invoke-GETAccountLock $ProfileId {
        $account=Read-GETAccount $ProfileId; Clear-GraphExplorerToken $account
        foreach ($ext in @('bin','json')) { $path=Get-GETAccountPath $ProfileId $ext; if ([IO.File]::Exists($path)) {[IO.File]::Delete($path)} }
    } } catch { Stop-GETAccountError $_ }
}

function Get-GraphAccountStatus {
    [CmdletBinding()]param([Parameter(Mandatory)][guid]$ProfileId)
    $stored=$null
    try {
        $account=Read-GETAccount $ProfileId; $info=Get-GraphExplorerTokenInfo $account
        if ($info.Status -eq 'ready') { return $info }
        if ($account.PersistToken -and [IO.File]::Exists((Get-GETAccountPath $ProfileId 'bin'))) {
            try {
                $stored=Read-GETProtectedToken $account
                return [pscustomobject]@{Status='saved'; ExpiresOn=$stored.ExpiresOn.ToString('o'); Source='windows_dpapi'; Verification='required_on_acquire'}
            } catch { if ($_.Exception.Message -eq 'token_expired') {return [pscustomobject]@{Status='expired'}}; throw }
        }
        [pscustomobject]@{Status='not_connected'}
    } catch { Stop-GETAccountError $_ } finally { if ($stored) {$stored.Token.Dispose()} }
}

function Get-GETAccountTokenCore($Account,[switch]$Force,[switch]$RefreshPage,[switch]$CacheOnly) {
    $profile=Resolve-GETProfile $Account; $key=Get-GETProfileKey $profile
    if (-not $Force -and -not $RefreshPage) {
        if ((Get-GraphExplorerTokenInfo $profile).Status -eq 'ready') {
            $entry=$script:TokenCache[$key]
            if ($entry.VerifiedAt -gt [DateTimeOffset]::UtcNow.AddMinutes(-5)) { return Get-GraphExplorerToken $profile }
            $copy=$entry.Token.Copy()
            try { $null=Connect-GraphExplorerToken -Profile $profile -Token $copy -Force; Write-GETProtectedToken $Account; return Get-GraphExplorerToken $profile }
            finally {$copy.Dispose()}
        }
        if ($Account.PersistToken -and [IO.File]::Exists((Get-GETAccountPath $Account.ProfileId 'bin'))) {
            $stored=$null
            try {
                $stored=Read-GETProtectedToken $Account
                # Every new process verifies the persisted credential with Graph, even if recently saved.
                $null=Connect-GraphExplorerToken -Profile $profile -Token $stored.Token -Force
                Write-GETProtectedToken $Account
                return Get-GraphExplorerToken $profile
            } catch { if ($_.Exception.Message -notin @('token_expired','graph_unauthorized')) {throw} }
            finally {if ($stored) {$stored.Token.Dispose()}}
        }
    }
    if ($CacheOnly) { throw 'interaction_required' }
    $raw=$null; $secure=$null
    try {
        $action=if ($RefreshPage) {'Refresh'} else {'Read'}
        try {
            $raw=Invoke-GETBrowserWorker -WindowHandle $Account.WindowHandle -AllowInteraction:($Account.AllowRefresh -or $RefreshPage) -Action $action
            $null=Read-GETClaims $raw $profile
        } catch {
            if ($_.Exception.Message -in @('wrong_account','wrong_tenant','required_scopes_missing','wrong_audience','invalid_token')) {throw}
            if ($Account.AllowRefresh -and -not $RefreshPage) {
                $raw=Invoke-GETBrowserWorker -WindowHandle $Account.WindowHandle -AllowInteraction -Action Refresh
                $null=Read-GETClaims $raw $profile
            } else {throw 'interaction_required'}
        }
        $secure=ConvertTo-SecureString $raw -AsPlainText -Force
        $null=Connect-GraphExplorerToken -Profile $profile -Token $secure -Force
        Write-GETProtectedToken $Account
        Get-GraphExplorerToken $profile
    } finally { $raw=$null; if ($secure) {$secure.Dispose()} }
}

function Get-GraphAccountToken {
    [CmdletBinding()][OutputType([Security.SecureString])]
    param([Parameter(Mandatory)][guid]$ProfileId,[switch]$Force,[switch]$RefreshPage,[switch]$CacheOnly)
    try {
        if ($CacheOnly -and ($Force -or $RefreshPage)) {throw 'invalid_profile'}
        Invoke-GETAccountLock $ProfileId { $account=Read-GETAccount $ProfileId; Get-GETAccountTokenCore $account -Force:$Force -RefreshPage:$RefreshPage -CacheOnly:$CacheOnly }
    } catch { Stop-GETAccountError $_ }
}

function Resolve-GETGraphUri([string]$Path) {
    if (-not $Path -or $Path.Length -gt 8192 -or $Path -match '[\s\\\x00-\x1f]' -or $Path -match '%(?:0[ad]|5c)') {throw 'invalid_graph_path'}
    $uri=$null
    $candidate=if ($Path.StartsWith('/')) {'https://graph.microsoft.com'+$Path} else {$Path}
    if (-not [uri]::TryCreate($candidate,[UriKind]::Absolute,[ref]$uri) -or $uri.Scheme -cne 'https' -or $uri.Host -cne 'graph.microsoft.com' -or $uri.Port -ne 443 -or $uri.UserInfo -or $uri.Fragment -or $uri.AbsolutePath -cnotmatch '^/(v1\.0|beta)/') {throw 'invalid_graph_path'}
    $uri
}

function Invoke-GETApiRequest([Security.SecureString]$Token,[uri]$Uri,[string]$Method,[string]$Body) {
    $handler=New-GETHttpHandler; $handler.AllowAutoRedirect=$false
    $client=[Net.Http.HttpClient]::new($handler); $client.Timeout=[TimeSpan]::FromSeconds(30)
    $client.MaxResponseContentBufferSize=16777216
    $request=[Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::new($Method),$Uri)
    $response=$null; $plain=$null
    try {
        $plain=ConvertFrom-GETSecureString $Token
        $request.Headers.Authorization=[Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer',$plain)
        if ($Body) {$request.Content=[Net.Http.StringContent]::new($Body,[Text.Encoding]::UTF8,'application/json')}
        try {$response=$client.SendAsync($request).GetAwaiter().GetResult()} catch {throw 'graph_unavailable'}
        $status=[int]$response.StatusCode
        switch ($status) {401 {throw 'graph_unauthorized'} 403 {throw 'graph_forbidden'} 429 {throw 'graph_throttled'}}
        if ($status -lt 200 -or $status -ge 300) {throw 'graph_request_failed'}
        if ($status -eq 204 -or $Method -eq 'HEAD') {return [pscustomobject]@{StatusCode=$status}}
        try { $json=$response.Content.ReadAsStringAsync().GetAwaiter().GetResult(); if (-not $json) {return}; $json | ConvertFrom-Json -Depth 64 }
        catch {throw 'graph_request_failed'}
    } finally {if ($response) {$response.Dispose()}; $request.Dispose(); $client.Dispose(); $plain=$null}
}

function Remove-GETRejectedToken([guid]$ProfileId,[Security.SecureString]$Rejected) {
    Invoke-GETAccountLock $ProfileId {
        $account=Read-GETAccount $ProfileId
        $key=Get-GETProfileKey (Resolve-GETProfile $account)
        if ($script:TokenCache.ContainsKey($key) -and (ConvertFrom-GETSecureString $script:TokenCache[$key].Token) -ceq (ConvertFrom-GETSecureString $Rejected)) {Remove-GETCacheEntry $key}
        $stored=$null
        try {
            if ($account.PersistToken -and [IO.File]::Exists((Get-GETAccountPath $ProfileId 'bin'))) {
                $stored=Read-GETProtectedToken $account
                if ((ConvertFrom-GETSecureString $stored.Token) -ceq (ConvertFrom-GETSecureString $Rejected)) {[IO.File]::Delete((Get-GETAccountPath $ProfileId 'bin'))}
            }
        } catch { # Unreadable/expired files cannot supply a usable credential; preserve them for diagnosis.
        } finally {if ($stored) {$stored.Token.Dispose()}}
    }
}

function Invoke-GraphAccountRequest {
    [CmdletBinding()]
    param([Parameter(Mandatory)][guid]$ProfileId,[string]$Path='/v1.0/me',[ValidateSet('GET','HEAD','POST','PATCH','PUT','DELETE')][string]$Method='GET',[string]$Body,[switch]$CacheOnly)
    $token=$null; $fresh=$null
    try {
        $uri=Resolve-GETGraphUri $Path
        if ($Body) {if ($Method -in @('GET','HEAD') -or $Body.Length -gt 1048576) {throw 'invalid_request_body'}; try {$null=$Body | ConvertFrom-Json -Depth 64} catch {throw 'invalid_request_body'}}
        $token=Get-GraphAccountToken -ProfileId $ProfileId -CacheOnly:$CacheOnly
        try { Invoke-GETApiRequest $token $uri $Method $Body }
        catch {
            # Only one replay of a read. Mutating Graph calls never retry automatically.
            $code=$_.Exception.Message
            if ($code -eq 'graph_unauthorized') {try {Remove-GETRejectedToken $ProfileId $token} catch {}}
            if ($code -ne 'graph_unauthorized' -or $Method -notin @('GET','HEAD') -or $CacheOnly) {throw $code}
            $fresh=Get-GraphAccountToken -ProfileId $ProfileId -Force
            $same=(ConvertFrom-GETSecureString $token) -ceq (ConvertFrom-GETSecureString $fresh)
            if ($same) {try {Remove-GETRejectedToken $ProfileId $fresh} catch {}; throw 'interaction_required'}
            try {Invoke-GETApiRequest $fresh $uri $Method $Body}
            catch {$code=$_.Exception.Message; if ($code -eq 'graph_unauthorized') {try {Remove-GETRejectedToken $ProfileId $fresh} catch {}}; throw $code}
        }
    } catch {Stop-GETAccountError $_}
    finally {if ($token) {$token.Dispose()}; if ($fresh) {$fresh.Dispose()}}
}
