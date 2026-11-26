# Automazioni con Graph Explorer

Questo percorso usa il token di Graph Explorer senza registrare una propria app Entra, creare secret o installare certificati. Il token resta soggetto a scadenza, revoca, MFA e policy dell'organizzazione.

## Preparare un profilo

Nella GUI usa **Accedi / scegli account**, seleziona la sessione Microsoft proposta, controlla l'identità rilevata e conferma. Abilita il salvataggio protetto per riusare il token da altri processi. Il tool genera un comando e può esportare uno script senza credenziali incorporate.

Il corrispondente percorso PowerShell, dopo avere completato l'accesso in Graph Explorer:

```powershell
Import-Module ./src/GraphExplorerToken/GraphExplorerToken.psd1
$candidate = New-GraphAccountDiscovery -AllowInteraction
$candidate.Identity # controlla nome, UPN, tenant e utente
$account = Save-GraphAccount -DiscoveryId $candidate.DiscoveryId `
    -Name 'Account di lavoro' -PersistToken
$account.ProfileId
```

Il rilevamento e la conferma devono avvenire nello stesso processo, entro cinque minuti. `Clear-GraphAccountDiscovery` annulla il candidato. Per scope aggiuntivi usa `-RequiredScopes @('User.Read','Mail.Read')` durante il rilevamento; il consenso va prima concesso in Graph Explorer.

`Start-GraphExplorerSignIn` avvia Sign in e restituisce `Accounts` e `LoginWindowHandle` se Microsoft presenta una scelta compatibile. `Select-GraphSignInAccount -LoginWindowHandle ... -Username ...` seleziona la scelta esatta; `__other__` indica il pulsante Microsoft «Usa un altro account». Le API non inseriscono password o approvano MFA. La GUI gestisce questi passaggi e la lista di scelta.

## Richieste Graph

```powershell
$id = '<ProfileId esplicito>'
Invoke-GraphAccountRequest -ProfileId $id `
    -Path '/v1.0/me?$select=id,displayName'

# Recupera ogni pagina esplicitamente. Anche nextLink viene validato dal wrapper.
$page = Invoke-GraphAccountRequest -ProfileId $id `
    -Path '/v1.0/me/messages?$top=10&$select=id,subject'
while ($page) {
    $page.value
    if (-not $page.'@odata.nextLink') { break }
    $page = Invoke-GraphAccountRequest -ProfileId $id -Path $page.'@odata.nextLink'
}
```

L'esempio dei messaggi richiede `Mail.Read`. Il wrapper non concede permessi. I metodi `POST`, `PATCH`, `PUT` e `DELETE` sono disponibili per le operazioni autorizzate dalla tua automazione; passa `-Body` con JSON valido. Nessuna operazione di scrittura viene ripetuta automaticamente. Prima di inserirla in un job, verifica destinatari, payload e permessi.

Per integrazioni che accettano un bearer `SecureString`:

```powershell
$token = Get-GraphAccountToken -ProfileId $id -CacheOnly
try {
    Invoke-RestMethod -Uri 'https://graph.microsoft.com/v1.0/me' `
        -Authentication Bearer -Token $token -MaximumRedirection 0
} finally { $token.Dispose() }
```

Non stampare il bearer, non inserirlo negli argomenti di processo, in variabili di ambiente o in log. `-CacheOnly` impedisce letture e interazioni con il browser; non impedisce la verifica HTTPS del token con Graph.

## Python e altri processi

La CLI espone risultati Graph e metadati in JSON, non il token:

```python
import json
import subprocess

result = subprocess.run([
    'pwsh', '-NoProfile', '-File', r'C:\Tools\GraphToken\scripts\Invoke-GraphAutomation.ps1',
    '-Action', 'Request', '-ProfileId', '<ProfileId>',
    '-Path', '/v1.0/me?$select=id,displayName', '-CacheOnly',
], capture_output=True, text=True, timeout=60)
data = json.loads(result.stdout)
if result.returncode:
    raise RuntimeError(data.get('error', 'graph_request_failed'))
print(data['displayName'])
```

Per una scrittura CLI usa `-Method` e `-BodyFile` per un file JSON, evitando payload nelle stringhe shell. Il limite del corpo è 1 MiB; il limite delle risposte è 16 MiB. Il wrapper non offre upload session, streaming o download binari.

## Scadenza e recupero assistito

La sequenza ordinaria è: memoria valida → cache DPAPI verificata → lettura passiva della finestra associata. Se hai abilitato `AllowRefresh`, il tool può selezionare Access token e tentare una sola ricarica della pagina, con un timeout. Il token risultante deve avere identità e scope attesi e almeno 180 secondi di validità residua.

```powershell
Set-GraphAccount -ProfileId $id -AllowRefresh $true
Get-GraphExplorerWindow # scegli la finestra corretta se sono presenti più account
Set-GraphAccount -ProfileId $id -WindowHandle <handle>
```

L'associazione a una finestra vale finché quella finestra esiste. Se la riapri, aggiorna il riferimento. Un token ancora scaduto dopo il refresh non viene dichiarato rinnovato. Quando serve intervento, il job termina con un codice di errore: completa login/MFA nel browser e ripeti il recupero. Evita loop infiniti di tentativi.

Un GET/HEAD che riceve 401 può effettuare un solo recupero e un solo retry, solo se il token è diverso; con `-CacheOnly` non viene eseguito questo recupero. Il 403 richiede una verifica dei permessi o delle policy e non provoca rinnovi ripetuti.

## Utilità di pianificazione

Esegui il job con lo **stesso utente Windows** che ha salvato la cache. Per il recupero tramite Edge usa **Esegui solo se l'utente è connesso**, con desktop disponibile e Graph Explorer visibile. La lettura non cerca schede inattive o finestre minimizzate; le interazioni attendono che il desktop sia inattivo.

Un'attività senza desktop può usare `-CacheOnly` e una credenziale ancora valida, se il processo dispone del profilo e delle chiavi DPAPI dell'utente. Non può ripristinare una sessione che richiede accesso interattivo. Non è garantita un'automazione continuativa senza operatore.

Il programma non registra attività pianificate automaticamente. Lo script esportato usa un percorso assoluto del modulo: aggiornalo se sposti il programma. Il token non è incluso nello script.

## Gestione locale

`Get-GraphAccountStatus` mostra stato/scadenza locali senza chiamare Graph. `Clear-GraphAccountToken -ProfileId ...` elimina la cache del processo e il file protetto; `Remove-GraphAccount` elimina anche il profilo. Altri processi possono conservare copie già acquisite. Nessuna di queste operazioni revoca la sessione Microsoft.

Il percorso standard è `%LOCALAPPDATA%\GraphExplorerTokenManager`. `GRAPH_TOKEN_MANAGER_HOME` serve a isolare test o installazioni: un override deve puntare a una directory locale privata, mai a una cartella condivisa o sincronizzata. I lock `.lock` sono file vuoti persistenti, non credenziali.
