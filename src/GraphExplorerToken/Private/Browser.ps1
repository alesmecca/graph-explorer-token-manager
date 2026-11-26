function Test-GETExplorerAddress([string]$Address) {
    $uri = $null
    if ($Address -match '[\s\\]' -or -not [uri]::TryCreate($Address,[UriKind]::Absolute,[ref]$uri)) { return $false }
    return $uri.Scheme -ceq 'https' -and $uri.Host -ceq 'developer.microsoft.com' -and
        $uri.Port -eq 443 -and -not $uri.UserInfo -and
        $uri.AbsolutePath -cmatch '^/(?:[a-z]{2}(?:-[a-z]{2})?/)?graph/graph-explorer/?$'
}

function Test-GETSignInAddress([string]$Address) {
    $uri=$null
    if ($Address -match '[\s\\]' -or -not [uri]::TryCreate($Address,[UriKind]::Absolute,[ref]$uri)) {return $false}
    $uri.Scheme -ceq 'https' -and $uri.Host -cin @('login.microsoftonline.com','login.live.com') -and $uri.Port -eq 443 -and -not $uri.UserInfo
}

function Test-GETGraphLoginAddress([string]$Address) {
    if (-not (Test-GETSignInAddress $Address)) {return $false}
    $uri=[uri]$Address
    # Published Microsoft Graph Explorer client ID, not an app registration created by this tool.
    $client=[Web.HttpUtility]::ParseQueryString($uri.Query)['client_id']
    $client -eq 'de8bc8b5-d9f9-48b1-a8ad-b748da725064'
}

function Test-GETReloadConfirmation([string]$Title,[string[]]$Buttons,[int]$DocumentDepth) {
    # Native before-unload prompt only. A page, MFA or consent dialog must not match.
    $DocumentDepth -eq 0 -and $Title.Trim() -match '^(?:Ricarica(?:re)? (?:il )?sito|Reload (?:this )?site)\??$' -and
        @($Buttons | Where-Object {$_ -cin @('Ricarica','Reload')}).Count -eq 1 -and
        @($Buttons | Where-Object {$_ -cin @('Annulla','Cancel')}).Count -eq 1
}

function Initialize-GETNativeInvoke {
    Add-Type -AssemblyName UIAutomationClient,UIAutomationTypes
    if (-not ('GraphExplorerToken.NativeInvoke' -as [type])) {
        $references=@([Windows.Automation.InvokePattern].Assembly.Location,[Windows.Automation.AutomationElement].Assembly.Location,[Windows.Automation.ControlType].Assembly.Location,(Join-Path $PSHOME 'ref/System.Threading.Thread.dll'))
        Add-Type -ReferencedAssemblies $references -TypeDefinition @'
using System;
using System.Threading;
using System.Windows.Automation;
namespace GraphExplorerToken {
    public sealed class NativeInvoke {
        public volatile bool Completed;
        public volatile bool Failed;
        public static NativeInvoke Begin(InvokePattern pattern) {
            var operation = new NativeInvoke();
            var thread = new Thread(() => {
                try { pattern.Invoke(); } catch { operation.Failed = true; }
                finally { operation.Completed = true; }
            });
            thread.IsBackground = true;
            thread.SetApartmentState(ApartmentState.MTA);
            thread.Start();
            return operation;
        }
    }
}
'@
    }
}

function Read-GETBrowserToken {
    [CmdletBinding()]
    [OutputType([string])]
    param([switch]$AllowInteraction,[ValidateRange(1,120)][int]$TimeoutSeconds=30,[long]$WindowHandle=0,[ValidateSet('Read','List','Refresh','SignIn','SelectAccount')][string]$Action='Read',[string]$AccountUsername)
    $ErrorActionPreference = 'Stop'
    if (-not $IsWindows) { throw 'unsupported_platform' }
    Initialize-GETNativeInvoke
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
        [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hwnd);
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
    function Assert-NoBrowserConfirmation($Root) {
        # Edge exposes before-unload prompts as a native pane/window outside the
        # Document. Inspect only title candidates, then verify their button pair.
        $titles=@('Ricarica sito','Ricarica sito?','Ricaricare il sito?','Reload site','Reload site?','Reload this site?')
        $conditions=[Windows.Automation.Condition[]]@($titles | ForEach-Object {[Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::NameProperty,$_)})
        $elements=$Root.FindAll([Windows.Automation.TreeScope]::Descendants,[Windows.Automation.OrCondition]::new($conditions))
        foreach ($element in $elements) {
            Check-Deadline
            if ($element.Current.IsOffscreen -or $element.Current.Name -notmatch '^(?:Ricarica(?:re)? (?:il )?sito|Reload (?:this )?site)\??$') {continue}
            $candidate=$element
            for ($level=0;$level -lt 3 -and $candidate;$level++) {
                if ([Windows.Automation.Automation]::Compare($candidate,$Root)) {break}
                $depth=Get-DocumentDepth $candidate $Root
                if ($depth -ne 0) {break}
                $names=@(Find-Controls $candidate ([Windows.Automation.ControlType]::Button) | Where-Object {-not $_.Current.IsOffscreen} | ForEach-Object {$_.Current.Name})
                if (Test-GETReloadConfirmation $element.Current.Name $names $depth) {
                    if ($AllowInteraction) {$null=[GraphExplorerToken.Desktop]::SetForegroundWindow([intptr]$Root.Current.NativeWindowHandle)}
                    throw 'browser_confirmation_required'
                }
                $candidate=[Windows.Automation.TreeWalker]::ControlViewWalker.GetParent($candidate)
            }
        }
    }
    function Find-Explorer([switch]$List) {
        $ids = [int[]]@(Get-Process msedge -ErrorAction SilentlyContinue | ForEach-Object Id)
        if (-not $ids.Count) { throw 'browser_unavailable' }
        $matches = @()
        foreach ($handle in [GraphExplorerToken.Desktop]::Windows($ids)) {
            Check-Deadline
            if (-not $List -and $WindowHandle -and $handle.ToInt64() -ne $WindowHandle) { continue }
            $root = [Windows.Automation.AutomationElement]::FromHandle($handle)
            if (Test-GETExplorerAddress (Read-Address $root)) { $matches += $root }
        }
        if ($List) { return $matches }
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
    function Read-AccountChoices($LoginRoot) {
        if (-not (Test-GETSignInAddress (Read-Address $LoginRoot))) {throw 'browser_origin_not_verified'}
        foreach ($button in (Find-Controls $LoginRoot ([Windows.Automation.ControlType]::Button))) {
            if ($button.Current.IsOffscreen -or -not $button.Current.IsEnabled -or (Get-DocumentDepth $button $LoginRoot) -ne 1) {continue}
            $name=$button.Current.Name
            if ($name -match '^(?:Accedere con|Accedi con|Sign in with)' -and $name -match '(?<username>[A-Za-z0-9._%+!#-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,})') {
                [pscustomobject]@{Username=$Matches.username; Button=$button}
            }
        }
    }
    if ($Action -eq 'SelectAccount') {
        if (-not $AllowInteraction -or -not $WindowHandle) {throw 'control_not_actionable'}
        $ids=[int[]]@(Get-Process msedge -ErrorAction SilentlyContinue | ForEach-Object Id)
        if ([intptr]$WindowHandle -notin [GraphExplorerToken.Desktop]::Windows($ids)) {throw 'browser_unavailable'}
        $loginRoot=[Windows.Automation.AutomationElement]::FromHandle([intptr]$WindowHandle)
        if (-not (Test-GETSignInAddress (Read-Address $loginRoot))) {throw 'browser_origin_not_verified'}
        if ($AccountUsername -eq '__other__') {
            $choices=@(foreach ($button in (Find-Controls $loginRoot ([Windows.Automation.ControlType]::Button))) {
                if (-not $button.Current.IsOffscreen -and $button.Current.Name -in @('Usa un altro account','Use another account') -and (Get-DocumentDepth $button $loginRoot) -eq 1) {$button}
            })
        } else {$choices=@(Read-AccountChoices $loginRoot | Where-Object Username -eq $AccountUsername | ForEach-Object Button)}
        if ($choices.Count -ne 1) {throw 'control_not_actionable'}
        if (-not (Test-GETSignInAddress (Read-Address $loginRoot))) {throw 'browser_origin_not_verified'}
        $null=[GraphExplorerToken.Desktop]::SetForegroundWindow([intptr]$WindowHandle)
        $pattern=$null
        if (-not $choices[0].TryGetCurrentPattern([Windows.Automation.InvokePattern]::Pattern,[ref]$pattern)) {throw 'control_not_actionable'}
        ([Windows.Automation.InvokePattern]$pattern).Invoke()
        return [pscustomobject]@{Status='account_selected'}
    }
    if ($Action -eq 'List') {
        foreach ($window in (Find-Explorer -List)) {
            [pscustomobject]@{ WindowHandle = [long]$window.Current.NativeWindowHandle; Browser = 'Edge'; Label = ('Graph Explorer - finestra ' + $window.Current.NativeWindowHandle) }
        }
        return
    }
    $root = Find-Explorer
    Assert-NoBrowserConfirmation $root
    if ($Action -eq 'SignIn') {
        if (-not $AllowInteraction) { throw 'control_not_actionable' }
        $buttons=@(foreach ($button in (Find-Controls $root ([Windows.Automation.ControlType]::Button))) {
            if (-not $button.Current.IsOffscreen -and $button.Current.IsEnabled -and $button.Current.Name -in @('Sign in','Accedi') -and (Get-DocumentDepth $button $root) -eq 1) { $button }
        })
        if ($buttons.Count -eq 0) {
            # Resume a Graph Explorer account picker left open by an earlier sign-in.
            # An unrelated Microsoft sign-in window is never reused.
            $ids=[int[]]@(Get-Process msedge -ErrorAction SilentlyContinue | ForEach-Object Id)
            $existing=@(foreach ($handle in [GraphExplorerToken.Desktop]::Windows($ids)) {
                $candidate=[Windows.Automation.AutomationElement]::FromHandle($handle)
                if (Test-GETGraphLoginAddress (Read-Address $candidate)) {$candidate}
            })
            if ($existing.Count -gt 1) {throw 'ambiguous_explorer_windows'}
            if ($existing.Count -eq 1) {
                return [pscustomobject]@{Status='choose_account'; GraphWindowHandle=[long]$root.Current.NativeWindowHandle; LoginWindowHandle=[long]$existing[0].Current.NativeWindowHandle; Accounts=@(Read-AccountChoices $existing[0] | ForEach-Object {[pscustomobject]@{Username=$_.Username}})}
            }
            return [pscustomobject]@{Status='sign_in_not_required_or_unavailable'; GraphWindowHandle=[long]$root.Current.NativeWindowHandle; LoginWindowHandle=0; Accounts=@()}
        }
        if ($buttons.Count -ne 1) { throw 'control_not_actionable' }
        while ([GraphExplorerToken.Desktop]::IdleMilliseconds() -lt 1500) {
            if ($clock.Elapsed.TotalSeconds -ge $TimeoutSeconds - 1) { throw 'desktop_in_use' }
            Start-Sleep -Milliseconds 150
        }
        if (-not (Test-GETExplorerAddress (Read-Address $root))) { throw 'browser_origin_not_verified' }
        $null=[GraphExplorerToken.Desktop]::SetForegroundWindow([intptr]$root.Current.NativeWindowHandle)
        $pattern=$null
        if (-not $buttons[0].TryGetCurrentPattern([Windows.Automation.InvokePattern]::Pattern,[ref]$pattern)) { throw 'control_not_actionable' }
        $ids=[int[]]@(Get-Process msedge -ErrorAction SilentlyContinue | ForEach-Object Id)
        $before=@([GraphExplorerToken.Desktop]::Windows($ids))
        ([Windows.Automation.InvokePattern]$pattern).Invoke()
        $result=[pscustomobject]@{Status='sign_in_started'; GraphWindowHandle=[long]$root.Current.NativeWindowHandle; LoginWindowHandle=[long]0; Accounts=@()}
        for ($attempt=0; $attempt -lt 16; $attempt++) {
            Check-Deadline; Start-Sleep -Milliseconds 400
            Assert-NoBrowserConfirmation $root
            $ids=[int[]]@(Get-Process msedge -ErrorAction SilentlyContinue | ForEach-Object Id)
            $loginWindows=@(foreach ($handle in [GraphExplorerToken.Desktop]::Windows($ids)) {
                if ($handle -in $before) {continue}
                $candidate=[Windows.Automation.AutomationElement]::FromHandle($handle)
                if (Test-GETSignInAddress (Read-Address $candidate)) {$candidate}
            })
            if ($loginWindows.Count -gt 1) {throw 'control_not_actionable'}
            if ($loginWindows.Count -eq 1) {
                $result.LoginWindowHandle=[long]$loginWindows[0].Current.NativeWindowHandle
                $result.Accounts=@(Read-AccountChoices $loginWindows[0] | ForEach-Object { [pscustomobject]@{Username=$_.Username} })
                if ($result.Accounts.Count) {$result.Status='choose_account'; break}
            }
        }
        return $result
    }
    if ($Action -eq 'Refresh') {
        if (-not $AllowInteraction) { throw 'control_not_actionable' }
        # Only Edge's own reload control, outside all web documents; never a page button.
        $reload = @()
        foreach ($button in (Find-Controls $root ([Windows.Automation.ControlType]::Button))) {
            if ($button.Current.IsOffscreen -or -not $button.Current.IsEnabled -or (Get-DocumentDepth $button $root) -ne 0) { continue }
            $name = $button.Current.Name -replace '\s+\((?i:Ctrl\+R|F5)\)$',''
            if ($name -notin @('Reload','Reload this page','Refresh','Refresh this page','Ricarica','Ricarica questa pagina','Aggiorna','Aggiorna questa pagina')) { continue }
            $parent = [Windows.Automation.TreeWalker]::ControlViewWalker.GetParent($button)
            for ($i=0; $i -lt 6 -and $parent; $i++) {
                if ($parent.Current.ControlType -eq [Windows.Automation.ControlType]::ToolBar) {
                    if (Test-GETExplorerAddress (Read-Address $parent)) { $reload += $button }
                    break
                }
                $parent = [Windows.Automation.TreeWalker]::ControlViewWalker.GetParent($parent)
            }
        }
        if ($reload.Count -ne 1) { throw 'control_not_actionable' }
        while ([GraphExplorerToken.Desktop]::IdleMilliseconds() -lt 3000) {
            if ($clock.Elapsed.TotalSeconds -ge $TimeoutSeconds - 2) { throw 'desktop_in_use' }
            Start-Sleep -Milliseconds 200
        }
        if (-not (Test-GETExplorerAddress (Read-Address $root))) { throw 'browser_origin_not_verified' }
        $pattern=$null
        if (-not $reload[0].TryGetCurrentPattern([Windows.Automation.InvokePattern]::Pattern,[ref]$pattern)) { throw 'control_not_actionable' }
        # Invoke can itself wait for a native modal dialog. Run it on a worker
        # thread so the main worker can detect that dialog and exit promptly.
        $reloadOperation=[GraphExplorerToken.NativeInvoke]::Begin([Windows.Automation.InvokePattern]$pattern)
        for ($attempt=0;$attempt -lt 8;$attempt++) {
            Start-Sleep -Milliseconds 150
            Assert-NoBrowserConfirmation $root
            if ($reloadOperation.Failed) {throw 'control_not_actionable'}
        }
        Assert-NoBrowserConfirmation $root
        # Reacquire controls after navigation; a page reload does not guarantee a new token.
        for ($attempt=0; $attempt -lt 30; $attempt++) {
            Check-Deadline
            Assert-NoBrowserConfirmation $root
            if (-not (Test-GETExplorerAddress (Read-Address $root))) { throw 'browser_origin_not_verified' }
            if (Find-PageTab $root @('Access token','Token di accesso')) { break }
            Start-Sleep -Milliseconds 250
        }
    }
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
            Assert-NoBrowserConfirmation $root
            if (-not (Test-GETExplorerAddress (Read-Address $root))) { throw 'browser_origin_not_verified' }
            $token = Read-Visible $root
        }
    }
    if (-not $token) { throw 'token_not_visible' }
    $current = Find-Explorer
    if (-not [Windows.Automation.Automation]::Compare($root,$current) -or -not (Test-GETExplorerAddress (Read-Address $root))) { throw 'browser_origin_not_verified' }
    return $token
}
