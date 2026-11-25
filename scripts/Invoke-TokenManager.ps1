#requires -Version 7.4
[CmdletBinding()]
param(
    [ValidateSet('Diagnose','Open','Connect')][string]$Action = 'Diagnose',
    [string]$ProfilePath,
    [switch]$AllowInteraction,
    [switch]$Manual
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '../src/GraphExplorerToken/GraphExplorerToken.psd1') -Force
try {
    switch ($Action) {
        Diagnose { Test-GraphExplorerEnvironment | ConvertTo-Json; exit 0 }
        Open { Open-GraphExplorer; exit 0 }
        Connect {
            if (-not $ProfilePath) { throw 'profile_path_required' }
            try {
                $data = Get-Content -LiteralPath $ProfilePath -Raw | ConvertFrom-Json -AsHashtable
                $profile = New-GraphExplorerProfile @data
            } catch { throw 'invalid_profile_file' }
            if ($Manual) {
                $inputToken = Read-Host 'Token Graph Explorer (input nascosto)' -AsSecureString
                try { $info = Connect-GraphExplorerToken -Profile $profile -Token $inputToken }
                finally { $inputToken.Dispose() }
            } else { $info = Connect-GraphExplorerToken -Profile $profile -AllowInteraction:$AllowInteraction }
            $info | ConvertTo-Json -Depth 4
        }
    }
} catch {
    $code = $_.Exception.Message
    if ($code -cnotmatch '^[a-z_]{3,80}$') { $code = 'operation_failed' }
    [pscustomobject]@{ Status = 'error'; Code = $code } | ConvertTo-Json -Compress
    exit 2
} finally { Clear-GraphExplorerToken }
