function Test-GETExplorerAddress([string]$Address) {
    $uri = $null
    if ($Address -match '[\s\\]' -or -not [uri]::TryCreate($Address,[UriKind]::Absolute,[ref]$uri)) { return $false }
    return $uri.Scheme -ceq 'https' -and $uri.Host -ceq 'developer.microsoft.com' -and
        $uri.Port -eq 443 -and -not $uri.UserInfo -and
        $uri.AbsolutePath -cmatch '^/(?:[a-z]{2}(?:-[a-z]{2})?/)?graph/graph-explorer/?$'
}

function Read-GETBrowserToken {
    [CmdletBinding()]
    [OutputType([string])]
    param([switch]$AllowInteraction,[ValidateRange(1,120)][int]$TimeoutSeconds=30)
    $ErrorActionPreference = 'Stop'
    if (-not $IsWindows) { throw 'unsupported_platform' }
    Add-Type -AssemblyName UIAutomationClient,UIAutomationTypes
    if (-not ('GraphExplorerToken.Desktop' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
namespace GraphExplorerToken {
    public static class Desktop {
        [StructLayout(LayoutKind.Sequential)] struct Input { public uint Size; public uint Tick; }
        delegate bool Callback(IntPtr hwnd, IntPtr parameter);
        [DllImport("user32.dll")] static extern bool EnumWindows(Callback callback, IntPtr parameter);
        [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
        [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr hwnd);
        [DllImport("user32.dll")] static extern bool IsIconic(IntPtr hwnd);
        [DllImport("user32.dll")] static extern bool GetLastInputInfo(ref Input input);
        public static IntPtr[] Windows(int[] processIds) {
            var result = new List<IntPtr>();
            EnumWindows((hwnd, p) => { uint pid; GetWindowThreadProcessId(hwnd, out pid);
                if (IsWindowVisible(hwnd) && !IsIconic(hwnd) && Array.IndexOf(processIds,(int)pid)>=0) result.Add(hwnd);
                return true;
            }, IntPtr.Zero);
            return result.ToArray();
        }
        public static uint IdleMilliseconds() {
            var input = new Input(); input.Size = (uint)Marshal.SizeOf(input);
            if (!GetLastInputInfo(ref input)) return 0;
            return unchecked((uint)Environment.TickCount - input.Tick);
        }
    }
}
'@
    }
    $clock = [Diagnostics.Stopwatch]::StartNew()
    function Check-Deadline { if ($clock.Elapsed.TotalSeconds -ge $TimeoutSeconds) { throw 'browser_timeout' } }
    function Find-Controls($Root,$Type) {
        Check-Deadline
        $elements = $Root.FindAll([Windows.Automation.TreeScope]::Descendants,
            [Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::ControlTypeProperty,$Type))
        if ($elements.Count -gt 10000) { throw 'browser_unavailable' }
        return $elements
    }
    function Get-DocumentDepth($Element,$Root) {
        $depth=0; $current=$Element
        for ($i=0; $i -lt 80 -and $null -ne $current; $i++) {
            Check-Deadline
            if ($current.Current.ControlType -eq [Windows.Automation.ControlType]::Document) { $depth++ }
            if ([Windows.Automation.Automation]::Compare($current,$Root)) { return $depth }
            $current = [Windows.Automation.TreeWalker]::ControlViewWalker.GetParent($current)
        }
        return -1
    }
    function Read-Address($Root) {
        $values = @()
        foreach ($el in (Find-Controls $Root ([Windows.Automation.ControlType]::Edit))) {
            if ($el.Current.IsOffscreen -or $el.Current.Name -notin @('Indirizzo e barra di ricerca','Address and search bar','Address bar','Barra degli indirizzi e di ricerca','Barra degli indirizzi')) { continue }
            if ((Get-DocumentDepth $el $Root) -ne 0) { continue }
            $pattern=$null
            if ($el.TryGetCurrentPattern([Windows.Automation.ValuePattern]::Pattern,[ref]$pattern)) { $values += ([Windows.Automation.ValuePattern]$pattern).Current.Value }
        }
        if ($values.Count -ne 1) { return $null }
        return $values[0]
    }
    function Find-Explorer {
        $ids = [int[]]@(Get-Process msedge -ErrorAction SilentlyContinue | ForEach-Object Id)
        if (-not $ids.Count) { throw 'browser_unavailable' }
        $matches = @()
        foreach ($handle in [GraphExplorerToken.Desktop]::Windows($ids)) {
            Check-Deadline
            $root = [Windows.Automation.AutomationElement]::FromHandle($handle)
            if (Test-GETExplorerAddress (Read-Address $root)) { $matches += $root }
        }
        if ($matches.Count -gt 1) { throw 'ambiguous_explorer_windows' }
        if ($matches.Count -eq 0) { throw 'graph_explorer_tab_not_found' }
        return $matches[0]
    }
    function Find-PageTab($Root,[string[]]$Names) {
        $tabs = @()
        foreach ($el in (Find-Controls $Root ([Windows.Automation.ControlType]::TabItem))) {
            if (-not $el.Current.IsOffscreen -and $el.Current.Name -in $Names -and (Get-DocumentDepth $el $Root) -eq 1) { $tabs += $el }
        }
        if ($tabs.Count -gt 1) { throw 'control_not_actionable' }
        if ($tabs.Count -eq 1) { return $tabs[0] }
        return $null
    }
    function Test-Selected($Tab) {
        if ($null -eq $Tab) { return $false }
        $pattern=$null
        if ($Tab.TryGetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern,[ref]$pattern)) {
            return ([Windows.Automation.SelectionItemPattern]$pattern).Current.IsSelected
        }
        return $false
    }
    function Select-PageTab($Root,$Tab) {
        if ($null -eq $Tab) { return }
        if (Test-Selected $Tab) { return }
        if (-not (Test-GETExplorerAddress (Read-Address $Root))) { throw 'browser_origin_not_verified' }
        # Never activate sign-in, consent, account-picker or browser navigation controls.
        while ([GraphExplorerToken.Desktop]::IdleMilliseconds() -lt 3000) {
            if ($clock.Elapsed.TotalSeconds -ge $TimeoutSeconds - 1) { throw 'desktop_in_use' }
            Start-Sleep -Milliseconds 200
        }
        Check-Deadline
        if (-not (Test-GETExplorerAddress (Read-Address $Root))) { throw 'browser_origin_not_verified' }
        $pattern=$null
        if (-not $Tab.TryGetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern,[ref]$pattern)) { throw 'control_not_actionable' }
        ([Windows.Automation.SelectionItemPattern]$pattern).Select()
    }
    function Read-Visible($Root) {
        $tab = Find-PageTab $Root @('Access token','Token di accesso')
        if (-not (Test-Selected $tab)) { return $null }
        $tokens = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($type in @([Windows.Automation.ControlType]::Text,[Windows.Automation.ControlType]::Edit)) {
            foreach ($el in (Find-Controls $Root $type)) {
                Check-Deadline
                if ($el.Current.IsOffscreen -or $el.Current.IsPassword) { continue }
                $value = $el.Current.Name
                if ($type -eq [Windows.Automation.ControlType]::Edit) {
                    $pattern=$null
                    if (-not $el.TryGetCurrentPattern([Windows.Automation.ValuePattern]::Pattern,[ref]$pattern)) { continue }
                    $value = ([Windows.Automation.ValuePattern]$pattern).Current.Value
                }
                if (-not $value -or $value.Length -gt 65536) { continue }
                # Match an entire token control; do not collect JWT fragments from response JSON.
                if ($value -cmatch '^eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$' -and (Get-DocumentDepth $el $Root) -eq 1) {
                    $null=$tokens.Add($value)
                }
            }
        }
        if ($tokens.Count -gt 1) { throw 'ambiguous_token_controls' }
        foreach ($token in $tokens) { return $token }
        return $null
    }
    $root = Find-Explorer
    $token = Read-Visible $root
    if (-not $token -and $AllowInteraction) {
        $tab = Find-PageTab $root @('Access token','Token di accesso')
        if ($null -eq $tab) {
            Select-PageTab $root (Find-PageTab $root @('Explorer','Esplora'))
            Start-Sleep -Milliseconds 300
            $tab = Find-PageTab $root @('Access token','Token di accesso')
        }
        Select-PageTab $root $tab
        for ($attempt=0; $attempt -lt 10 -and -not $token; $attempt++) {
            Check-Deadline; Start-Sleep -Milliseconds 200
            if (-not (Test-GETExplorerAddress (Read-Address $root))) { throw 'browser_origin_not_verified' }
            $token = Read-Visible $root
        }
    }
    if (-not $token) { throw 'token_not_visible' }
    $current = Find-Explorer
    if (-not [Windows.Automation.Automation]::Compare($root,$current) -or -not (Test-GETExplorerAddress (Read-Address $root))) { throw 'browser_origin_not_verified' }
    return $token
}
