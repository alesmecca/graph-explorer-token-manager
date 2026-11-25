#requires -Version 7.4
$ErrorActionPreference='Stop'
$module=Import-Module (Join-Path $PSScriptRoot '../src/GraphExplorerToken/GraphExplorerToken.psd1') -Force -PassThru
Add-Type -TypeDefinition @'
using System;
using System.Net;
using System.Net.Http;
using System.Threading;
using System.Threading.Tasks;
public class OfflineGraphHandler : HttpClientHandler {
    public static int Status=200, Calls;
    public static string Body, Method, Address;
    public static bool Redirects, HasBearer, Fail;
    protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellation) {
        Calls++; Method=request.Method.Method; Address=request.RequestUri.ToString(); Redirects=AllowAutoRedirect;
        HasBearer=request.Headers.Authorization!=null && request.Headers.Authorization.Scheme=="Bearer";
        if (Fail) throw new HttpRequestException("OFFLINE_SECRET_CANARY");
        return Task.FromResult(new HttpResponseMessage((HttpStatusCode)Status){Content=new StringContent(Body)});
    }
}
'@
& $module {function script:New-GETHttpHandler { [OfflineGraphHandler]::new() }}
$profile=New-GraphExplorerProfile -TenantId '11111111-1111-4111-8111-111111111111' -AccountObjectId '22222222-2222-4222-8222-222222222222'
$cases=@(
    @{Status=200;Body='{"id":"22222222-2222-4222-8222-222222222222"}';Code=$null},
    @{Status=200;Body='{"id":"33333333-3333-4333-8333-333333333333"}';Code='graph_identity_mismatch'},
    @{Status=200;Body='{}';Code='graph_identity_mismatch'},
    @{Status=200;Body='invalid';Code='graph_identity_mismatch'},
    @{Status=204;Body='';Code='graph_unavailable'},
    @{Status=302;Body='';Code='graph_unavailable'},
    @{Status=401;Body='';Code='graph_unauthorized'},
    @{Status=403;Body='';Code='graph_forbidden'},
    @{Status=429;Body='';Code='graph_throttled'},
    @{Status=500;Body='';Code='graph_unavailable'},
    @{Status=200;Body='';Code='graph_unavailable';Fail=$true}
)
$passed=0
try {
    foreach ($case in $cases) {
        [OfflineGraphHandler]::Status=$case.Status; [OfflineGraphHandler]::Body=$case.Body
        [OfflineGraphHandler]::Fail=[bool]$case.Fail; [OfflineGraphHandler]::Calls=0
        $code=$null
        try { & $module {param($p) Invoke-GETIdentityCheck 'OFFLINE_SECRET_CANARY' $p} $profile } catch {$code=$_.Exception.Message}
        if ($code -ne $case.Code) {throw "Unexpected safe error for HTTP $($case.Status)"}
        if ([OfflineGraphHandler]::Calls -ne 1 -or [OfflineGraphHandler]::Redirects -or -not [OfflineGraphHandler]::HasBearer -or
            [OfflineGraphHandler]::Method -ne 'GET' -or [OfflineGraphHandler]::Address -cne 'https://graph.microsoft.com/v1.0/me?$select=id') {throw 'HTTP request contract failed'}
        $passed++
    }
} finally {Remove-Module -ModuleInfo $module -Force}
Write-Host "HTTP: $passed offline cases passed; no network calls."
