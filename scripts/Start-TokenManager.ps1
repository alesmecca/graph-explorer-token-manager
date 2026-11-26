#requires -Version 7.4
[CmdletBinding()]param([switch]$SmokeTest,[string]$PreviewPath)
$ErrorActionPreference='Stop'
if (-not $IsWindows) {throw 'Windows required.'}
if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {throw 'Start with pwsh -STA -File scripts/Start-TokenManager.ps1'}
Add-Type -AssemblyName System.Windows.Forms,System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()
$modulePath=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../src/GraphExplorerToken/GraphExplorerToken.psd1'))
Import-Module $modulePath -Force
$script:task=$null; $script:async=$null; $script:token=$null; $script:expires=$null
$script:pending=$null; $script:cancelled=$false; $script:closing=$false; $script:loading=$false
$script:accountItems=@(); $script:windowItems=@(); $script:operation=''
$runspace=[RunspaceFactory]::CreateRunspace(); $runspace.Open()
$initialize=[PowerShell]::Create(); $initialize.Runspace=$runspace
$null=$initialize.AddCommand('Import-Module').AddParameter('Name',$modulePath)
$null=$initialize.Invoke(); $initialize.Dispose()
$script:errors=@{
    invalid_profile='Nome, permessi o profilo non validi.'
    profile_not_found='Seleziona un account salvato oppure aggiungine uno.'
    profile_store_invalid='Un profilo locale non è leggibile. Consulta docs/troubleshooting.md.'
    cache_corrupt='Cache protetta non leggibile o non associata al profilo. Usa Recupera da Edge per sostituirla.'
    cache_unavailable='Windows non ha potuto salvare il token protetto. Controlla la cartella locale.'
    graph_explorer_tab_not_found='Apri Graph Explorer in Edge, completa Accedi e lascia la pagina visibile.'
    browser_unavailable='Apri Microsoft Edge con Graph Explorer.'
    browser_origin_not_verified='Pagina non verificabile. Torna al Graph Explorer ufficiale in Edge.'
    ambiguous_explorer_windows='Più finestre Graph Explorer: premi Cerca finestre e scegli quella desiderata.'
    token_not_visible='Completa Accedi in Graph Explorer e apri Access token; poi riprova Rileva account.'
    ambiguous_token_controls='Lascia visibile soltanto il pannello Access token di Graph Explorer.'
    desktop_in_use='Lascia mouse e tastiera inattivi per qualche secondo durante il recupero.'
    wrong_tenant='Il browser mostra un tenant diverso dal profilo selezionato.'
    wrong_account='Il browser mostra un altro account. Il profilo selezionato non cambia identità.'
    required_scopes_missing='Permessi mancanti: concedili in Modify permissions su Graph Explorer, quindi rileggi il token.'
    token_expired='Token scaduto o troppo vicino alla scadenza. Accedi nuovamente o aggiorna Graph Explorer.'
    graph_unauthorized='Graph rifiuta il token: completa nuovamente Accedi in Graph Explorer.'
    graph_forbidden='Permessi insufficienti o policy del tenant. Verifica User.Read e i permessi della richiesta.'
    graph_identity_mismatch='Microsoft Graph ha restituito una identità diversa da quella attesa.'
    graph_throttled='Graph limita le richieste. Attendi prima di riprovare.'
    graph_unavailable='Graph non raggiungibile: controlla rete e proxy.'
    browser_timeout='Tempo di lettura del browser esaurito. Riprova o usa Incolla token.'
    browser_confirmation_required='Edge richiede conferma della ricarica. Scegli Ricarica o Annulla nel dialogo del browser, poi riprova. Nessuna conferma è stata premuta automaticamente.'
    unsupported_token_format='Questo strumento richiede un token JWT leggibile.'
    invalid_token='Token non riconosciuto o incompleto.'
    wrong_audience='Il token non è destinato a Microsoft Graph.'
    discovery_expired='La verifica da confermare è scaduta. Premi di nuovo Rileva account.'
    interaction_required='Serve un token valido: apri Graph Explorer con questo account, completa eventuale login/MFA e premi Recupera da Edge.'
    control_not_actionable='Edge non espone il controllo necessario. Aggiorna la pagina manualmente e riprova.'
    profile_busy='Un altro processo sta usando il profilo. Riprova tra poco.'
}
$form=[Windows.Forms.Form]::new(); $form.Text='Graph Explorer Token Manager 2.0.0'
$form.ClientSize=[Drawing.Size]::new(1060,780); $form.MinimumSize=[Drawing.Size]::new(1076,819)
$form.StartPosition='CenterScreen'; $form.Font=[Drawing.Font]::new('Segoe UI',10)
$form.BackColor=[Drawing.Color]::FromArgb(246,248,252)
function Label([string]$Text,[int]$X,[int]$Y,[int]$Width,[int]$Height=24) {
    $c=[Windows.Forms.Label]::new(); $c.Text=$Text; $c.Location=[Drawing.Point]::new($X,$Y); $c.Size=[Drawing.Size]::new($Width,$Height); $form.Controls.Add($c); $c
}
function InputBox([int]$X,[int]$Y,[int]$Width,[int]$Height=28,[switch]$ReadOnly) {
    $c=[Windows.Forms.TextBox]::new(); $c.Location=[Drawing.Point]::new($X,$Y); $c.Size=[Drawing.Size]::new($Width,$Height)
    $c.ReadOnly=[bool]$ReadOnly; $c.Multiline=($Height -gt 30); if ($c.Multiline) {$c.ScrollBars='Vertical'}
    $c.BackColor=[Drawing.Color]::White; $form.Controls.Add($c); $c
}
function Button([string]$Text,[int]$X,[int]$Y,[int]$Width) {
    $c=[Windows.Forms.Button]::new(); $c.Text=$Text; $c.Location=[Drawing.Point]::new($X,$Y); $c.Size=[Drawing.Size]::new($Width,34); $c.FlatStyle='Flat'; $form.Controls.Add($c); $c
}
function Combo([int]$X,[int]$Y,[int]$Width) {
    $c=[Windows.Forms.ComboBox]::new(); $c.DropDownStyle='DropDownList'; $c.Location=[Drawing.Point]::new($X,$Y); $c.Size=[Drawing.Size]::new($Width,30); $form.Controls.Add($c); $c
}
function Check([string]$Text,[int]$X,[int]$Y,[int]$Width,[int]$Height=28) {
    $c=[Windows.Forms.CheckBox]::new(); $c.Text=$Text; $c.Location=[Drawing.Point]::new($X,$Y); $c.Size=[Drawing.Size]::new($Width,$Height); $form.Controls.Add($c); $c
}
$title=Label 'Graph Explorer, dall''accesso alle automazioni.' 24 18 1000 38
$title.Font=[Drawing.Font]::new('Segoe UI',19,[Drawing.FontStyle]::Bold)
$null=Label 'Nessuna app da registrare. Accedi con Microsoft, conferma l''account e riusa il token nei tuoi script.' 24 61 1000
$accounts=Combo 24 96 635; $add=Button 'Aggiungi account' 677 94 175; $remove=Button 'Rimuovi profilo' 865 94 170
$section=Label '1. Accedi e scegli l''account in Graph Explorer' 24 146 635; $section.Font=[Drawing.Font]::new('Segoe UI',11,[Drawing.FontStyle]::Bold)
$open=Button 'Accedi / scegli account' 24 178 200; $private=Button 'Altro account: InPrivate' 236 178 238; $manual=Button 'Incolla token...' 486 178 173
$windows=Combo 24 225 355; $find=Button 'Cerca finestre' 391 222 128; $discover=Button 'Rileva account' 531 222 128
$identity=InputBox 24 271 635 108 -ReadOnly
$identity.Text="Primo utilizzo:`r`n1. Premi Accedi / scegli account: il tool avvia Sign in su Graph Explorer.`r`n2. Scegli un account salvato; completa password o MFA solo se richiesti.`r`n3. Controlla l'identità rilevata e conferma. Nessun GUID da cercare."
$null=Label '2. Controlla l''identità e configura il profilo' 24 392 635
$null=Label 'Nome del profilo' 24 424 235; $name=InputBox 24 450 250
$null=Label 'Permessi richiesti (separati da spazi)' 292 424 367; $scopes=InputBox 292 450 367; $scopes.Text='User.Read'
$persist=Check 'Salva il token protetto con Windows per riusarlo da altri script' 24 490 635
$refresh=Check 'Consenti di selezionare Access token e aggiornare la pagina quando serve' 24 523 635 40
$confirm=Button 'Usa questo account' 24 576 210; $confirm.BackColor=[Drawing.Color]::FromArgb(24,84,185); $confirm.ForeColor=[Drawing.Color]::White
$settings=Button 'Salva impostazioni' 246 576 200; $cancel=Button 'Annulla rilevamento' 458 576 201
$status=InputBox 24 631 635 125 -ReadOnly; $status.Text='Pronto. Il token resta in memoria finché non scegli il salvataggio protetto.'
$right=Label '3. Usa il profilo selezionato' 695 146 340; $right.Font=[Drawing.Font]::new('Segoe UI',11,[Drawing.FontStyle]::Bold)
$acquire=Button 'Recupera da Edge' 695 180 340; $reload=Button 'Aggiorna pagina e rileggi token' 695 224 340
$copy=Button 'Copia token' 695 268 160; $clear=Button 'Cancella token' 867 268 168
$null=Label 'La copia usa gli appunti di Windows; cronologia e sincronizzazione possono conservarla.' 695 315 340 48
$test=Button 'Prova automazione: GET /me' 695 375 340
$null=Label 'Comando per un nuovo processo PowerShell' 695 429 340 44
$command=InputBox 695 479 340 126 -ReadOnly; $export=Button 'Esporta script .ps1' 695 617 340
$null=Label 'Il token scade. Un nuovo login/MFA può essere necessario. Il refresh della pagina non garantisce un nuovo token.' 695 672 340 84
$interactive=@($accounts,$add,$remove,$open,$private,$manual,$windows,$find,$discover,$name,$scopes,$persist,$refresh,$confirm,$settings,$acquire,$reload,$copy,$clear,$test,$export)

function Clear-SessionToken {if ($script:token) {$script:token.Dispose(); $script:token=$null}; $script:expires=$null; $copy.Enabled=$false}
function Selected-Account {if ($accounts.SelectedIndex -ge 0 -and $accounts.SelectedIndex -lt $script:accountItems.Count) {$script:accountItems[$accounts.SelectedIndex]}}
function Selected-Window {if ($windows.SelectedIndex -gt 0 -and $windows.SelectedIndex -le $script:windowItems.Count) {return [long]$script:windowItems[$windows.SelectedIndex-1].WindowHandle}; return [long]0}
function Update-Enabled {
    $busy=$null -ne $script:task; $selected=$null -ne (Selected-Account)
    foreach ($c in $interactive) {$c.Enabled=-not $busy}
    $confirm.Enabled=-not $busy -and $null -ne $script:pending
    $scopes.Enabled=-not $busy -and -not $script:pending
    foreach ($c in @($remove,$settings,$acquire,$reload,$clear,$test,$export)) {$c.Enabled=-not $busy -and $selected -and -not $script:pending}
    $copy.Enabled=-not $busy -and $null -ne $script:token -and $selected -and -not $script:pending
    $cancel.Enabled=($busy -and $script:operation -eq 'Discover' -and -not $script:cancelled) -or (-not $busy -and $null -ne $script:pending)
}
function Safe-Error([string]$Code) {
    $hint=$script:errors[$Code]; if (-not $hint) {$hint='Operazione non completata. Consulta docs/troubleshooting.md.'}; $status.Text="$hint`r`nCodice: $Code"
}
function Reload-Accounts([string]$SelectId) {
    $script:loading=$true
    try {$script:accountItems=@(Get-GraphAccount | Sort-Object Name); $accounts.Items.Clear()
        foreach ($a in $script:accountItems) {$null=$accounts.Items.Add("$($a.Name) | $($a.UserPrincipalName)")}
        if ($script:accountItems.Count) {$index=0; for ($i=0;$i -lt $script:accountItems.Count;$i++) {if ($script:accountItems[$i].ProfileId -eq $SelectId) {$index=$i}}; $accounts.SelectedIndex=$index}
    } finally {$script:loading=$false}
    Show-Selected
}
function Show-Selected {
    Clear-SessionToken; $a=Selected-Account
    if ($a) {
        $name.Text=$a.Name; $scopes.Text=$a.RequiredScopes -join ' '; $persist.Checked=$a.PersistToken; $refresh.Checked=$a.AllowRefresh
        $identity.Text="Account confermato: $($a.DisplayName)`r`n$($a.UserPrincipalName)`r`nTenant: $($a.TenantId)`r`nProfileId: $($a.ProfileId)"
        $command.Text="pwsh -NoProfile -File `"$([IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'Invoke-GraphAutomation.ps1')))`" -ProfileId $($a.ProfileId) -Action Request -Path '/v1.0/me'"
        $status.Text='Profilo selezionato. Recupera da Edge oppure prova GET /me. Per cambiare finestra usa Cerca finestre e Salva impostazioni.'
    } else {$command.Clear()}
    Update-Enabled
}
function Start-Operation([string]$Operation,[hashtable]$Data=@{}) {
    if ($script:task) {return}
    $script:operation=$Operation; $script:cancelled=$false
    $script:task=[PowerShell]::Create(); $script:task.Runspace=$runspace
    $null=$script:task.AddScript({
        param($Action,$Data)
        $ErrorActionPreference='Stop'; $value=$null; $owned=$null
        try {
            switch ($Action) {
                'Login' {$value=Start-GraphExplorerSignIn -InPrivate:$Data.InPrivate -WindowHandle $Data.Window}
                'SelectAccount' {$value=Select-GraphSignInAccount -LoginWindowHandle $Data.Window -Username $Data.Username; Start-Sleep -Seconds 2}
                'Windows' {$value=@(Get-GraphExplorerWindow)}
                'Discover' {
                    if ($Data.Token) {$value=New-GraphAccountDiscovery -Token $Data.Token -RequiredScopes $Data.Scopes}
                    else {
                        $loginClock=[Diagnostics.Stopwatch]::StartNew()
                        while ($true) {
                            try {$value=New-GraphAccountDiscovery -WindowHandle $Data.Window -AllowInteraction -RequiredScopes $Data.Scopes; break}
                            catch {
                                if (-not $Data.WaitForSignIn -or $_.Exception.Message -notin @('token_not_visible','graph_explorer_tab_not_found','desktop_in_use')) {throw}
                                if ($loginClock.Elapsed.TotalSeconds -ge 45) {throw 'interaction_required'}
                                Start-Sleep -Milliseconds 750
                            }
                        }
                    }
                }
                'Confirm' {$value=Save-GraphAccount -DiscoveryId $Data.Id -Name $Data.Name -PersistToken:$Data.Persist -AllowRefresh:$Data.Refresh}
                'Settings' {$options=@{ProfileId=$Data.Id; Name=$Data.Name; PersistToken=$Data.Persist; AllowRefresh=$Data.Refresh; RequiredScopes=$Data.Scopes}; if ($Data.Window) {$options.WindowHandle=$Data.Window}; $value=Set-GraphAccount @options}
                'Acquire' {$owned=Get-GraphAccountToken -ProfileId $Data.Id -Force -RefreshPage:$Data.RefreshPage; $value=Get-GraphAccountStatus -ProfileId $Data.Id}
                'Test' {$null=Invoke-GraphAccountRequest -ProfileId $Data.Id -Path '/v1.0/me?$select=id'; $value=Get-GraphAccountStatus -ProfileId $Data.Id}
                'Clear' {Clear-GraphAccountToken -ProfileId $Data.Id}
                'Remove' {Remove-GraphAccount -ProfileId $Data.Id}
                'Cancel' {Clear-GraphAccountDiscovery}
            }
            [pscustomobject]@{Value=$value; Token=$owned; Code=$null}
        } catch {if ($owned) {$owned.Dispose()}; $code=$_.Exception.Message; if ($code -cnotmatch '^[a-z_]{3,80}$') {$code='operation_failed'}; [pscustomobject]@{Value=$null; Token=$null; Code=$code}}
        finally {if ($Data.Token) {$Data.Token.Dispose()}}
    }).AddArgument($Operation).AddArgument($Data)
    $script:async=$script:task.BeginInvoke(); Update-Enabled
    $status.Text='Operazione in corso. Browser e rete hanno timeout limitati.'
}
$timer=[Windows.Forms.Timer]::new(); $timer.Interval=200
$timer.Add_Tick({
    if ($script:task -and $script:async.IsCompleted) {
        $operation=$script:operation; $cancelled=$script:cancelled; $result=$null
        try {$result=$script:task.EndInvoke($script:async) | Select-Object -Last 1}
        catch {$result=[pscustomobject]@{Code='operation_failed'; Token=$null}}
        finally {$script:task.Dispose(); $script:task=$null; $script:async=$null}
        if ($cancelled) {if ($result.Token) {$result.Token.Dispose()}; $script:pending=$null; Start-Operation Cancel}
        elseif (-not $result -or $result.Code) {Safe-Error $(if ($result) {$result.Code} else {'operation_failed'})}
        else {
            switch ($operation) {
                'Login' {
                    $script:loginGraphWindow=[long]$result.Value.GraphWindowHandle
                    if ($result.Value.Status -eq 'choose_account' -and @($result.Value.Accounts | Where-Object {$_ -and $_.Username}).Count) {Show-LoginChoices $result.Value}
                    else {Start-Operation Discover @{Window=$script:loginGraphWindow; Scopes=@($scopes.Text -split '\s+' | Where-Object {$_}); Token=$null; WaitForSignIn=$true}}
                }
                'SelectAccount' {Start-Operation Discover @{Window=$script:loginGraphWindow; Scopes=@($scopes.Text -split '\s+' | Where-Object {$_}); Token=$null; WaitForSignIn=$true}}
                'Windows' {$script:windowItems=@($result.Value); $windows.Items.Clear(); $null=$windows.Items.Add('Automatico: unica finestra Graph Explorer'); foreach ($w in $script:windowItems) {$null=$windows.Items.Add($w.Label)}; $windows.SelectedIndex=0; $status.Text="Finestre trovate: $($script:windowItems.Count). Scegli quella desiderata; il token sarà verificato per identità."}
                'Discover' {$script:pending=$result.Value; $v=$result.Value; $identity.Text="Verificato da Microsoft Graph: $($v.Identity.DisplayName)`r`n$($v.Identity.UserPrincipalName)`r`nTenant: $($v.Identity.TenantId)`r`nScadenza: $([DateTimeOffset]::Parse($v.ExpiresOn).ToLocalTime())"; $name.Text=if ($v.Identity.DisplayName) {$v.Identity.DisplayName} else {'Account Graph'}; $status.Text='Controlla l''account e premi Usa questo account. La conferma è valida per 5 minuti.'}
                'Confirm' {$script:pending=$null; Reload-Accounts $result.Value.ProfileId; $status.Text='Account salvato. Il comando a destra usa questo ProfileId. Prova automazione esegue GET /me.'}
                'Settings' {Reload-Accounts $result.Value.ProfileId; $status.Text='Impostazioni salvate. Se hai cambiato i permessi, recupera di nuovo il token.'}
                'Acquire' {Clear-SessionToken; $script:token=$result.Token; $script:expires=[DateTimeOffset]::Parse($result.Value.ExpiresOn); $status.Text="Token verificato per il profilo selezionato.`r`nScadenza: $($script:expires.ToLocalTime())`r`nPermessi: $($result.Value.GrantedScopes -join ', ')"}
                'Test' {$status.Text='Automazione riuscita: GET /me ha risposto con il token del profilo selezionato.'}
                'Clear' {Clear-SessionToken; $status.Text='Token cancellato dalla cache del programma e dal file protetto. Sessione Microsoft e appunti non sono revocati.'}
                'Remove' {$script:pending=$null; Reload-Accounts; $status.Text='Profilo e token protetto rimossi.'}
                'Cancel' {$script:pending=$null; $status.Text='Rilevamento annullato. Nessun account confermato.'}
            }
        }
        Update-Enabled
        if ($script:closing -and -not $script:task) {$form.Close()}
    }
    if ($script:token -and $script:expires -le [DateTimeOffset]::UtcNow.AddSeconds(180)) {Clear-SessionToken; $status.Text='Token vicino alla scadenza: recupera un token valido.'}
})
function Show-LoginChoices($Login) {
    $dialog=[Windows.Forms.Form]::new(); $dialog.Text='Scegli l''account Microsoft'; $dialog.ClientSize=[Drawing.Size]::new(600,280); $dialog.StartPosition='CenterParent'; $dialog.Font=$form.Font
    # The browser worker may have activated Edge. Keep this owned chooser above it
    # only for the lifetime of the modal dialog, never the main application.
    if ($form.WindowState -eq 'Minimized') {$form.WindowState='Normal'}
    $dialog.TopMost=$true; $dialog.ShowInTaskbar=$false
    $dialog.Add_Shown({$this.Activate(); $this.BringToFront()})
    $caption=[Windows.Forms.Label]::new(); $caption.Text='Account proposti dalla pagina di accesso Microsoft:'; $caption.Location=[Drawing.Point]::new(20,20); $caption.Size=[Drawing.Size]::new(560,30)
    $list=[Windows.Forms.ListBox]::new(); $list.Location=[Drawing.Point]::new(20,60); $list.Size=[Drawing.Size]::new(560,140)
    foreach ($a in $Login.Accounts) {$null=$list.Items.Add($a.Username)}; $null=$list.Items.Add('Usa un altro account'); $list.SelectedIndex=0
    $ok=[Windows.Forms.Button]::new(); $ok.Text='Continua'; $ok.Location=[Drawing.Point]::new(440,220); $ok.Size=[Drawing.Size]::new(140,34); $ok.DialogResult='OK'
    $back=[Windows.Forms.Button]::new(); $back.Text='Annulla'; $back.Location=[Drawing.Point]::new(290,220); $back.Size=[Drawing.Size]::new(140,34); $back.DialogResult='Cancel'
    $dialog.Controls.AddRange(@($caption,$list,$back,$ok)); $dialog.AcceptButton=$ok; $dialog.CancelButton=$back
    try {if ($dialog.ShowDialog($form) -eq 'OK') {
        $username=if ($list.SelectedIndex -eq @($Login.Accounts).Count) {'__other__'} else {$Login.Accounts[$list.SelectedIndex].Username}
        Start-Operation SelectAccount @{Window=$Login.LoginWindowHandle; Username=$username}
    } else {$status.Text='Scelta account annullata. La pagina Microsoft resta aperta.'}}
    finally {$dialog.TopMost=$false; $dialog.Dispose()}
}
$null=$windows.Items.Add('Automatico: unica finestra Graph Explorer'); $windows.SelectedIndex=0
$accounts.Add_SelectedIndexChanged({if (-not $script:loading) {$script:pending=$null; Show-Selected}})
$add.Add_Click({$script:pending=$null; $accounts.SelectedIndex=-1; Clear-SessionToken; $name.Clear(); $scopes.Text='User.Read'; $persist.Checked=$false; $refresh.Checked=$false; $identity.Text="Premi Accedi / scegli account oppure InPrivate per un altro account.`r`nIl tool avvia Sign in e attende la verifica dell'identità.`r`nCompleta password o MFA nel browser soltanto se richiesti."; $status.Text='Nuovo account. Scegli la sessione Microsoft e conferma l''identità rilevata.'; Update-Enabled})
$open.Add_Click({Clear-SessionToken; $script:pending=$null; Start-Operation Login @{InPrivate=$false; Window=(Selected-Window)}})
$private.Add_Click({Clear-SessionToken; $script:pending=$null; Start-Operation Login @{InPrivate=$true; Window=0}})
$find.Add_Click({Start-Operation Windows})
$discover.Add_Click({Clear-SessionToken; $script:pending=$null; Start-Operation Discover @{Window=(Selected-Window); Scopes=@($scopes.Text -split '\s+' | Where-Object {$_}); Token=$null}})
$confirm.Add_Click({Start-Operation Confirm @{Id=$script:pending.DiscoveryId; Name=$name.Text; Persist=$persist.Checked; Refresh=$refresh.Checked}})
$settings.Add_Click({Start-Operation Settings @{Id=(Selected-Account).ProfileId; Name=$name.Text; Persist=$persist.Checked; Refresh=$refresh.Checked; Window=(Selected-Window); Scopes=@($scopes.Text -split '\s+' | Where-Object {$_})}})
$cancel.Add_Click({if ($script:task) {$script:cancelled=$true; $cancel.Enabled=$false; $status.Text='Annullamento richiesto: il risultato sarà scartato. Chiusura del recupero entro il timeout.'} else {$script:pending=$null; Start-Operation Cancel}})
$acquire.Add_Click({Clear-SessionToken; Start-Operation Acquire @{Id=(Selected-Account).ProfileId; RefreshPage=$false}})
$reload.Add_Click({Clear-SessionToken; Start-Operation Acquire @{Id=(Selected-Account).ProfileId; RefreshPage=$true}})
$test.Add_Click({Start-Operation Test @{Id=(Selected-Account).ProfileId}})
$clear.Add_Click({Start-Operation Clear @{Id=(Selected-Account).ProfileId}})
$remove.Add_Click({if ([Windows.Forms.MessageBox]::Show($form,'Rimuovere profilo e token protetto?','Rimuovi profilo','YesNo','Question') -eq 'Yes') {Start-Operation Remove @{Id=(Selected-Account).ProfileId}}})
$copy.Add_Click({
    if (-not $script:token -or $script:expires -le [DateTimeOffset]::UtcNow.AddSeconds(180)) {Clear-SessionToken; return}
    $ptr=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($script:token)
    try {[Windows.Forms.Clipboard]::SetText([Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)); $status.AppendText("`r`nToken copiato negli appunti.")}
    catch {$status.AppendText("`r`nAppunti occupati. Riprova.")}
    finally {[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)}
})
$export.Add_Click({
    $dialog=[Windows.Forms.SaveFileDialog]::new(); $dialog.Filter='PowerShell (*.ps1)|*.ps1'; $dialog.FileName='Invoke-MyGraphAutomation.ps1'
    try {if ($dialog.ShowDialog($form) -eq 'OK') {
        $text="#requires -Version 7.4`r`n`$ErrorActionPreference = 'Stop'`r`nImport-Module '"+$modulePath.Replace("'","''")+"'`r`nInvoke-GraphAccountRequest -ProfileId '"+(Selected-Account).ProfileId+"' -Path '/v1.0/me?`$select=id,displayName'`r`n"
        [IO.File]::WriteAllText($dialog.FileName,$text,[Text.UTF8Encoding]::new($false)); $status.Text='Script esportato con percorso modulo e ProfileId. Nessun token incluso.'
    }} finally {$dialog.Dispose()}
})
$manual.Add_Click({
    $dialog=[Windows.Forms.Form]::new(); $dialog.Text='Token da Graph Explorer: verifica account'; $dialog.ClientSize=[Drawing.Size]::new(580,150); $dialog.StartPosition='CenterParent'; $dialog.Font=$form.Font
    $input=[Windows.Forms.TextBox]::new(); $input.UseSystemPasswordChar=$true; $input.Location=[Drawing.Point]::new(20,25); $input.Width=540; $input.MaxLength=65536
    $ok=[Windows.Forms.Button]::new(); $ok.Text='Verifica'; $ok.Location=[Drawing.Point]::new(430,80); $ok.Size=[Drawing.Size]::new(130,34); $ok.DialogResult='OK'
    $dialog.Controls.AddRange(@($input,$ok)); $dialog.AcceptButton=$ok
    try {if ($dialog.ShowDialog($form) -eq 'OK' -and $input.Text) {$secure=ConvertTo-SecureString $input.Text.Trim() -AsPlainText -Force; $input.Clear(); Clear-SessionToken; $script:pending=$null; Start-Operation Discover @{Token=$secure; Scopes=@($scopes.Text -split '\s+' | Where-Object {$_})}}}
    finally {$input.Clear(); $dialog.Dispose()}
})
$form.Add_FormClosing({param($sender,$eventArgs) if ($script:task) {$eventArgs.Cancel=$true; $script:closing=$true; if ($script:operation -eq 'Discover') {$script:cancelled=$true}; $status.Text='Chiusura al termine dell''operazione in corso, entro il timeout.'}})
try {
    if ($SmokeTest) {
        Update-Enabled
        if ($confirm.Enabled -or $copy.Enabled -or $acquire.Enabled) {throw 'Unsafe initial GUI state'}
        function Get-GraphAccount {
            [pscustomobject]@{ProfileId='33333333-3333-4333-8333-333333333333'; Name='Offline saved account'; DisplayName='Offline'; UserPrincipalName='test@example.invalid'; TenantId='22222222-2222-4222-8222-222222222222'; RequiredScopes=@('User.Read'); PersistToken=$false; AllowRefresh=$false}
        }
        Reload-Accounts
        if ($accounts -isnot [Windows.Forms.ComboBox] -or $accounts.Items.Count -ne 1 -or (Selected-Account).Name -ne 'Offline saved account' -or -not $acquire.Enabled) {throw 'Saved account GUI binding failed'}
        $accounts.Items.Clear(); $script:accountItems=@(); $command.Clear()
        $offline=@{Delay=100; Fail=$false; Cleared=0}
        $mock=[PowerShell]::Create(); $mock.Runspace=$runspace
        $null=$mock.AddScript({param($State)
            $global:GuiTestState=$State
            function global:New-GraphAccountDiscovery {
                param($WindowHandle,$RequiredScopes,[switch]$AllowInteraction,$Token)
                Start-Sleep -Milliseconds $global:GuiTestState.Delay
                if ($global:GuiTestState.Fail) {throw 'graph_unavailable'}
                [pscustomobject]@{DiscoveryId='11111111-1111-4111-8111-111111111111'; Identity=[pscustomobject]@{DisplayName='Offline GUI account'; UserPrincipalName='test@example.invalid'; TenantId='22222222-2222-4222-8222-222222222222'}; ExpiresOn=[DateTimeOffset]::UtcNow.AddHours(1).ToString('o')}
            }
            function global:Clear-GraphAccountDiscovery {$global:GuiTestState.Cleared++}
            function global:Get-GraphExplorerWindow {[pscustomobject]@{WindowHandle=12345; Label='Offline window'}}
            function global:Start-GraphExplorerSignIn {param($WindowHandle,[switch]$InPrivate) [pscustomobject]@{Status='sign_in_not_required_or_unavailable'; GraphWindowHandle=12345; LoginWindowHandle=0; Accounts=@()}}
        }).AddArgument($offline)
        $null=$mock.Invoke(); $mock.Dispose()
        function Wait-GuiTest {
            $watch=[Diagnostics.Stopwatch]::StartNew()
            while ($script:task -and $watch.Elapsed.TotalSeconds -lt 8) {[Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 10}
            if ($script:task) {throw 'GUI async timeout'}
        }
        $timer.Start()
        Start-Operation Windows; Wait-GuiTest
        $windows.SelectedIndex=1
        if ($windows -isnot [Windows.Forms.ComboBox] -or (Selected-Window) -ne 12345) {throw 'Window selector binding failed'}
        $windows.Items.Clear(); $script:windowItems=@(); $null=$windows.Items.Add('Automatico: unica finestra Graph Explorer'); $windows.SelectedIndex=0
        Start-Operation Login @{Window=0; InPrivate=$false}; Wait-GuiTest
        if (-not $script:pending -or -not $confirm.Enabled) {throw 'Existing-session login did not progress to discovery'}
        $script:pending=$null
        Start-Operation Discover @{Window=0; Scopes=@('User.Read'); Token=$null}
        if ($accounts.Enabled -or $add.Enabled -or $copy.Enabled -or -not $cancel.Enabled) {throw 'Unsafe busy GUI state'}
        Wait-GuiTest
        if (-not $script:pending -or -not $confirm.Enabled -or $scopes.Enabled -or $copy.Enabled) {throw 'Incorrect discovery confirmation state'}
        $script:pending=$null; $offline.Delay=350
        Start-Operation Discover @{Window=0; Scopes=@('User.Read'); Token=$null}
        $script:cancelled=$true
        Wait-GuiTest
        if ($script:pending -or $confirm.Enabled -or $offline.Cleared -ne 1) {throw 'Late cancelled result was retained'}
        $offline.Fail=$true
        Start-Operation Discover @{Window=0; Scopes=@('User.Read'); Token=$null}; Wait-GuiTest
        if ($script:pending -or $confirm.Enabled -or -not $discover.Enabled) {throw 'GUI failed to recover after error'}
        $offline.Fail=$false
        Start-Operation Discover @{Window=0; Scopes=@('User.Read'); Token=$null}; Wait-GuiTest
        if (-not $script:pending -or -not $confirm.Enabled) {throw 'GUI retry failed'}
        $script:pending=$null; $name.Clear(); $identity.Text="Primo utilizzo:`r`n1. Premi Accedi / scegli account: il tool avvia Sign in su Graph Explorer.`r`n2. Scegli un account salvato; completa password o MFA solo se richiesti.`r`n3. Controlla l'identità rilevata e conferma. Nessun GUID da cercare."
        $status.Text='Pronto. Il token resta in memoria finché non scegli il salvataggio protetto.'
        $timer.Stop(); Update-Enabled
        if ($PreviewPath) {
            $bitmap=[Drawing.Bitmap]::new($form.Width,$form.Height)
            try {$form.DrawToBitmap($bitmap,[Drawing.Rectangle]::new(0,0,$form.Width,$form.Height)); $border=[int](($form.Width-$form.ClientSize.Width)/2); $top=$form.Height-$form.ClientSize.Height-$border
                foreach ($c in $form.Controls) {$c.DrawToBitmap($bitmap,[Drawing.Rectangle]::new($border+$c.Left,$top+$c.Top,$c.Width,$c.Height))}
                $bitmap.Save([IO.Path]::GetFullPath($PreviewPath),[Drawing.Imaging.ImageFormat]::Png)
            } finally {$bitmap.Dispose()}
        }
        'GUI: construction, saved profiles, windows, existing-session login, busy, confirmation, late cancellation and error/retry states passed.'
    } else {try {Reload-Accounts} catch {Safe-Error $_.Exception.Message}; $timer.Start(); [Windows.Forms.Application]::Run($form)}
} finally {$timer.Stop(); $timer.Dispose(); Clear-SessionToken; $runspace.Close(); $runspace.Dispose(); $form.Dispose(); Clear-GraphExplorerToken; Clear-GraphAccountDiscovery}
