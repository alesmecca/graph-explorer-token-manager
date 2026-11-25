#requires -Version 7.4
[CmdletBinding()]
param([switch]$SmokeTest,[string]$PreviewPath)
$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { throw 'Windows required.' }
if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') { throw 'Start with pwsh -STA -File scripts/Start-TokenManager.ps1' }
Add-Type -AssemblyName System.Windows.Forms,System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()
$modulePath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../src/GraphExplorerToken/GraphExplorerToken.psd1'))
Import-Module $modulePath -Force
$script:task = $null; $script:async = $null; $script:token = $null; $script:expires = $null
$script:errors = @{
    invalid_profile = 'Inserire tenant e Object ID validi, e permessi separati da spazi.'
    graph_explorer_tab_not_found = 'Aprire Graph Explorer in Edge e selezionare la scheda Access token.'
    browser_origin_not_verified = 'Impossibile verificare la pagina: usare Graph Explorer ufficiale in Edge con interfaccia italiana o inglese.'
    ambiguous_explorer_windows = 'Sono aperte più finestre Graph Explorer. Lasciarne una sola visibile.'
    token_not_visible = 'Selezionare Access token in Graph Explorer dopo il login, oppure usare Incolla token.'
    ambiguous_token_controls = 'Più token visibili. Lasciare visibile soltanto il pannello Access token.'
    desktop_in_use = 'Interazione sospesa: lasciare mouse e tastiera inattivi per alcuni secondi e riprovare.'
    wrong_tenant = 'Il token appartiene a un tenant diverso dal profilo.'
    wrong_account = 'Il token appartiene a un account diverso dal profilo.'
    required_scopes_missing = 'Mancano permessi richiesti. Controllare Modify permissions in Graph Explorer.'
    token_expired = 'Token scaduto o troppo vicino alla scadenza. Rinnovare la sessione in Graph Explorer.'
    token_not_yet_valid = 'Token non ancora valido. Controllare orologio del PC e sessione.'
    graph_unauthorized = 'Graph ha rifiutato il token. Accedere nuovamente in Graph Explorer.'
    graph_forbidden = 'Graph nega /me. Verificare il consenso User.Read e le policy del tenant.'
    graph_identity_mismatch = 'La risposta Graph non corrisponde all''Object ID atteso.'
    graph_throttled = 'Graph ha limitato le richieste. Attendere prima di riprovare.'
    graph_unavailable = 'Graph non è raggiungibile. Controllare rete, proxy e riprovare.'
    browser_timeout = 'La lettura del browser ha superato il timeout. Usare Incolla token o riprovare.'
    unsupported_token_format = 'Formato token non supportato: questa versione richiede un JWT leggibile.'
    invalid_token = 'Il valore inserito non è un token supportato.'
    wrong_audience = 'Il token non è destinato a Microsoft Graph.'
}
$form = [Windows.Forms.Form]::new()
$form.Text = 'Graph Explorer Token Manager 1.0.0'
$form.ClientSize = [Drawing.Size]::new(780,650)
$form.MinimumSize = [Drawing.Size]::new(796,689)
$form.StartPosition = 'CenterScreen'
$form.Font = [Drawing.Font]::new('Segoe UI',10)
$form.BackColor = [Drawing.Color]::FromArgb(246,248,252)

function Add-Label([string]$Text,[int]$X,[int]$Y,[int]$Width=710,[int]$Height=25) {
    $control = [Windows.Forms.Label]::new(); $control.Text = $Text
    $control.Location = [Drawing.Point]::new($X,$Y); $control.Size = [Drawing.Size]::new($Width,$Height)
    $form.Controls.Add($control); return $control
}
function Add-Input([int]$Y) {
    $control = [Windows.Forms.TextBox]::new(); $control.Location = [Drawing.Point]::new(24,$Y)
    $control.Size = [Drawing.Size]::new(730,28); $form.Controls.Add($control); return $control
}
function Add-Button([string]$Text,[int]$X,[int]$Y,[int]$Width) {
    $control = [Windows.Forms.Button]::new(); $control.Text = $Text
    $control.Location = [Drawing.Point]::new($X,$Y); $control.Size = [Drawing.Size]::new($Width,36)
    $control.FlatStyle = 'Flat'; $form.Controls.Add($control); return $control
}
$title = Add-Label 'Il tuo token Graph, pronto per gli strumenti di lavoro.' 24 20 730 34
$title.Font = [Drawing.Font]::new('Segoe UI',16,[Drawing.FontStyle]::Bold)
$null = Add-Label '1. Configura l''identità   2. Accedi in Graph Explorer   3. Recupera e verifica' 24 61
$null = Add-Label 'Tenant ID' 24 99
$tenant = Add-Input 126
$null = Add-Label 'Object ID dell''utente nel tenant selezionato' 24 164
$account = Add-Input 191
$null = Add-Label 'Permessi richiesti (separati da spazi; User.Read è sempre incluso)' 24 229
$scopes = Add-Input 256; $scopes.Text = 'User.Read'
$load = Add-Button 'Carica profilo' 24 300 140
$save = Add-Button 'Salva profilo' 174 300 140
$open = Add-Button 'Apri Graph Explorer' 324 300 200
$diagnose = Add-Button 'Diagnosi' 534 300 220
$interaction = [Windows.Forms.CheckBox]::new(); $interaction.Text = 'Consenti di selezionare le schede di Edge quando il desktop è inattivo'
$interaction.Location = [Drawing.Point]::new(24,350); $interaction.Size = [Drawing.Size]::new(730,28)
$form.Controls.Add($interaction)
$connect = Add-Button 'Recupera e verifica' 24 390 220
$connect.BackColor = [Drawing.Color]::FromArgb(24,84,185); $connect.ForeColor = [Drawing.Color]::White
$manual = Add-Button 'Incolla token…' 254 390 170
$copy = Add-Button 'Copia token' 434 390 150; $copy.Enabled = $false
$clear = Add-Button 'Svuota memoria' 594 390 160
$status = [Windows.Forms.TextBox]::new(); $status.Multiline = $true; $status.ReadOnly = $true
$status.ScrollBars = 'Vertical'; $status.Location = [Drawing.Point]::new(24,445); $status.Size = [Drawing.Size]::new(730,135)
$status.BackColor = [Drawing.Color]::White; $status.Text = 'Pronto. I token restano nella memoria di questa sessione.'
$form.Controls.Add($status)
$null = Add-Label 'La copia esplicita usa gli appunti di Windows: attenzione a cronologia e sincronizzazione.' 24 592 730 44

function Clear-SessionToken {
    if ($script:token) { $script:token.Dispose(); $script:token = $null }
    $script:expires = $null; $copy.Enabled = $false
}
function Read-FormProfile {
    New-GraphExplorerProfile -TenantId $tenant.Text.Trim() -AccountObjectId $account.Text.Trim() -RequiredScopes @($scopes.Text -split '\s+' | Where-Object { $_ })
}
function Set-Busy([bool]$Busy) {
    foreach ($control in @($connect,$manual,$load,$save,$tenant,$account,$scopes,$interaction,$clear)) { $control.Enabled = -not $Busy }
    $copy.Enabled = -not $Busy -and $null -ne $script:token
}
function Begin-Connect([Security.SecureString]$ManualToken) {
    try { $profile = Read-FormProfile } catch { $status.Text = $script:errors.invalid_profile; return }
    Clear-SessionToken; Set-Busy $true
    $status.Text = 'Lettura e verifica in corso… Login, MFA e consenso restano manuali in Edge.'
    $script:task = [PowerShell]::Create()
    $null = $script:task.AddScript({
        param($ModulePath,$Profile,$AllowInteraction,$ManualToken)
        Import-Module $ModulePath -Force
        try {
            if ($ManualToken) { $info = Connect-GraphExplorerToken -Profile $Profile -Token $ManualToken -Force }
            else { $info = Connect-GraphExplorerToken -Profile $Profile -AllowInteraction:$AllowInteraction -Force }
            [pscustomobject]@{ Info = $info; Token = Get-GraphExplorerToken -Profile $Profile; Code = $null }
        } catch {
            $code = $_.Exception.Message
            if ($code -cnotmatch '^[a-z_]{3,80}$') { $code = 'operation_failed' }
            [pscustomobject]@{ Info = $null; Token = $null; Code = $code }
        } finally { Clear-GraphExplorerToken; if ($ManualToken) { $ManualToken.Dispose() } }
    }).AddArgument($modulePath).AddArgument($profile).AddArgument($interaction.Checked).AddArgument($ManualToken)
    $script:async = $script:task.BeginInvoke()
}
$timer = [Windows.Forms.Timer]::new(); $timer.Interval = 250
$timer.Add_Tick({
    if ($script:task -and $script:async.IsCompleted) {
        try {
            $results = $script:task.EndInvoke($script:async)
            $result = $results | Select-Object -Last 1
            if (-not $result -or $result.Code) {
                $code = if ($result) { $result.Code } else { 'operation_failed' }
                $hint = $script:errors[$code]
                if (-not $hint) { $hint = 'Operazione non completata. Consultare docs/troubleshooting.md.' }
                $status.Text = "$hint`r`nCodice: $code"
            } else {
                $script:token = $result.Token; $script:expires = [DateTimeOffset]::Parse($result.Info.ExpiresOn)
                $status.Text = "Verificato da Microsoft Graph /me.`r`nScadenza: $($script:expires.ToLocalTime().ToString('dd/MM/yyyy HH:mm:ss'))`r`nPermessi: $($result.Info.GrantedScopes -join ', ')`r`nIl token non viene mostrato. Usa Copia token solo quando necessario."
            }
        } catch { $status.Text = 'Operazione non completata (operation_failed).' }
        finally { $script:task.Dispose(); $script:task = $null; $script:async = $null; Set-Busy $false }
    }
    if ($script:token -and $script:expires -le [DateTimeOffset]::UtcNow.AddSeconds(180)) {
        Clear-SessionToken; $status.Text = 'Token prossimo alla scadenza: recuperare un token aggiornato.'
    }
})
$tenant.Add_TextChanged({ Clear-SessionToken }); $account.Add_TextChanged({ Clear-SessionToken }); $scopes.Add_TextChanged({ Clear-SessionToken })
$connect.Add_Click({ Begin-Connect $null })
$open.Add_Click({ try { Open-GraphExplorer } catch { $status.Text = 'Impossibile aprire Edge. Aprire manualmente Graph Explorer.' } })
$diagnose.Add_Click({ $status.Text = Test-GraphExplorerEnvironment | ConvertTo-Json })
$clear.Add_Click({ Clear-SessionToken; $status.Text = 'Token rimosso dalla memoria. Eventuali copie negli appunti restano sotto il tuo controllo.' })
$copy.Add_Click({
    if (-not $script:token -or $script:expires -le [DateTimeOffset]::UtcNow.AddSeconds(180)) { Clear-SessionToken; return }
    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($script:token)
    try { [Windows.Forms.Clipboard]::SetText([Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)); $status.AppendText("`r`nToken copiato negli appunti.") }
    catch { $status.AppendText("`r`nAppunti occupati: riprovare.") }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
})
$load.Add_Click({
    $dialog = [Windows.Forms.OpenFileDialog]::new(); $dialog.Filter = 'Profilo JSON (*.json)|*.json'
    try {
        if ($dialog.ShowDialog() -eq 'OK') {
            $data = Get-Content -LiteralPath $dialog.FileName -Raw | ConvertFrom-Json -AsHashtable
            $profile = New-GraphExplorerProfile @data
            if ($profile.MinimumValiditySeconds -ne 180) { throw 'GUI supports a 180 second margin' }
            $tenant.Text = $profile.TenantId; $account.Text = $profile.AccountObjectId; $scopes.Text = $profile.RequiredScopes -join ' '
            $status.Text = 'Profilo caricato. Nessun token è contenuto nel file.'
        }
    } catch { $status.Text = 'Profilo non valido. La GUI usa un margine di scadenza di 180 secondi.' }
    finally { $dialog.Dispose() }
})
$save.Add_Click({
    $dialog = [Windows.Forms.SaveFileDialog]::new(); $dialog.Filter = 'Profilo locale (*.local.json)|*.local.json'; $dialog.FileName = 'profile.local.json'
    try {
        $profile = Read-FormProfile
        if ($dialog.ShowDialog() -eq 'OK') { $profile | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $dialog.FileName -Encoding utf8; $status.Text = 'Profilo salvato. Il file contiene solo identità e permessi richiesti.' }
    } catch { $status.Text = 'Impossibile salvare: verificare i campi e il percorso.' }
    finally { $dialog.Dispose() }
})
$manual.Add_Click({
    $dialog = [Windows.Forms.Form]::new(); $dialog.Text = 'Incolla il tuo token Graph Explorer'; $dialog.Size = [Drawing.Size]::new(600,190)
    $dialog.StartPosition = 'CenterParent'; $dialog.Font = $form.Font
    $input = [Windows.Forms.TextBox]::new(); $input.UseSystemPasswordChar = $true; $input.Location = [Drawing.Point]::new(20,25); $input.Width = 540
    $ok = [Windows.Forms.Button]::new(); $ok.Text = 'Verifica'; $ok.Location = [Drawing.Point]::new(430,75); $ok.DialogResult = 'OK'; $ok.Width = 130
    $dialog.Controls.AddRange(@($input,$ok)); $dialog.AcceptButton = $ok
    try {
        if ($dialog.ShowDialog($form) -eq 'OK' -and $input.Text) {
            $secure = ConvertTo-SecureString -String $input.Text.Trim() -AsPlainText -Force; $input.Clear()
            try { Begin-Connect $secure } finally { if (-not $script:task) { $secure.Dispose() } }
        }
    } finally { $input.Clear(); $dialog.Dispose() }
})
$form.Add_FormClosing({ param($sender,$eventArgs)
    if ($script:task) { $eventArgs.Cancel = $true; $status.AppendText("`r`nAttendere la fine della verifica (timeout limitato) prima di chiudere.") }
})
try {
    if ($SmokeTest) {
        if ($PreviewPath) {
            $bitmap=[Drawing.Bitmap]::new($form.Width,$form.Height)
            try {
                $form.DrawToBitmap($bitmap,[Drawing.Rectangle]::new(0,0,$form.Width,$form.Height))
                # Draw children individually without showing or activating a window.
                $border=[int](($form.Width-$form.ClientSize.Width)/2)
                $top=$form.Height-$form.ClientSize.Height-$border
                foreach ($control in $form.Controls) {
                    $control.DrawToBitmap($bitmap,[Drawing.Rectangle]::new($border+$control.Left,$top+$control.Top,$control.Width,$control.Height))
                }
                $bitmap.Save([IO.Path]::GetFullPath($PreviewPath),[Drawing.Imaging.ImageFormat]::Png)
            } finally {$bitmap.Dispose()}
        }
        'GUI controls constructed successfully.'
    }
    else { $timer.Start(); [Windows.Forms.Application]::Run($form) }
} finally { $timer.Stop(); $timer.Dispose(); Clear-SessionToken; $form.Dispose(); Clear-GraphExplorerToken }
