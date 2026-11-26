# Graph Explorer Token Manager

[![Windows tests](https://github.com/alesmecca/graph-explorer-token-manager/actions/workflows/ci.yml/badge.svg)](https://github.com/alesmecca/graph-explorer-token-manager/actions/workflows/ci.yml)

Accedi a **Microsoft Graph Explorer**, scegli l'account e riusa il suo access token nelle automazioni PowerShell. **Nessuna registrazione applicativa, client secret o certificato da configurare.** Il tool riconosce tenant e utente e verifica l'identità con Microsoft Graph prima di confermare il profilo.

**2.0.0 · Windows 10/11 · PowerShell 7.4+ · Edge in italiano o inglese · Microsoft cloud globale.**

![Interfaccia Windows](docs/assets/manager.png)

## Primo utilizzo

1. Scarica ed estrai lo ZIP dalle [Releases](https://github.com/alesmecca/graph-explorer-token-manager/releases/latest). Installa [PowerShell 7](https://learn.microsoft.com/powershell/scripting/install/installing-powershell-on-windows) se manca.
2. Avvia **Start-GraphExplorerTokenManager.cmd** e premi **Accedi / scegli account**. Il programma apre Graph Explorer se necessario e attiva il suo pulsante Sign in.
3. Se Microsoft propone account già salvati, scegli quello desiderato nella finestra del tool. La selezione viene applicata alla pagina Microsoft verificata. Per una nuova identità usa **Altro account: InPrivate** oppure **Usa un altro account** nella scelta proposta.
4. La sessione Microsoft esistente può completare l'accesso. Se vengono richiesti password, MFA o consenso, completali nel browser, quindi premi **Rileva account**. Non inserirli nel tool.
5. Controlla nome, indirizzo e tenant rilevati. Assegna un nome al profilo e premi **Usa questo account**. Non servono Tenant ID o Object ID digitati a mano.
6. Per riusare il token da altri processi, seleziona **Salva il token protetto con Windows** prima della conferma. Poi premi **Prova automazione: GET /me** o **Esporta script .ps1**.

Il riconoscimento non salva un account prima della conferma; il candidato scade dopo cinque minuti. Più profili possono coesistere. Il profilo selezionato vincola sempre tenant e utente: un account diverso nel browser non viene sostituito silenziosamente.

La selezione degli account dipende dai controlli esposti dalla pagina Microsoft. Se la pagina usa un flusso diverso, scegli l'account direttamente nel browser e premi **Rileva account**. Le finestre InPrivate possono condividere la stessa sessione. Le policy aziendali possono disabilitare InPrivate.

## Finestre, permessi e recupero

**Cerca finestre** elenca soltanto finestre Edge visibili con Graph Explorer attivo. Se ce ne sono più di una, scegli quella desiderata. Per associarla a un profilo esistente premi **Salva impostazioni**; se la finestra viene chiusa, cercala e associala di nuovo. In modalità automatica serve una sola finestra compatibile.

`User.Read` è sempre richiesto per `/me`. Puoi aggiungere scope separati da spazi, per esempio `Mail.Read`. Il tool verifica quelli presenti nel token: scriverli nel profilo **non concede permessi**. Usa **Modify permissions** in Graph Explorer per i consensi necessari. Cambiare gli scope richiesti invalida il token salvato.

**Recupera da Edge** forza una nuova lettura. **Aggiorna pagina e rileggi token** autorizza un aggiornamento della pagina verificata e un nuovo controllo del token. L'opzione di aggiornamento nel profilo permette anche alle automazioni di tentare questa operazione quando manca un token valido. Un aggiornamento della pagina non garantisce che Microsoft emetta un token nuovo.

La scelta account resta in primo piano sopra Edge. Se Edge richiede **Ricarica sito**, il tool interrompe l'attesa con `browser_confirmation_required`: scegli Ricarica o Annulla nel browser e riprova. Il tool non conferma la perdita di eventuali modifiche alla pagina.

Se i controlli del browser cambiano, **Incolla token** offre un campo nascosto e lo stesso riconoscimento/verifica dell'identità. La copia negli appunti è sempre esplicita.

## Automazione senza token negli script

Dalla cartella del programma:

```powershell
Import-Module ./src/GraphExplorerToken/GraphExplorerToken.psd1
Get-GraphAccount | Select-Object ProfileId, Name, UserPrincipalName

$profileId = '<ProfileId del profilo scelto>'
Invoke-GraphAccountRequest -ProfileId $profileId `
    -Path '/v1.0/me?$select=id,displayName'
```

Il `ProfileId` identifica la configurazione locale, non è una credenziale. Usa sempre un profilo esplicito. Il wrapper accetta percorsi `/v1.0/...` e `/beta/...` oppure URL HTTPS del solo host `graph.microsoft.com`, disabilita redirect e applica timeout. Non segue automaticamente la paginazione; valida anche un eventuale `@odata.nextLink` quando lo passi alla chiamata successiva.

Per processi che devono evitare qualsiasi accesso al browser:

```powershell
Invoke-GraphAccountRequest -ProfileId $profileId -Path '/v1.0/me' -CacheOnly
```

La cache protetta deve essere ancora valida. Ogni nuovo processo verifica il bearer con Graph `/me` prima dell'uso; la memoria del processo può riusare una verifica per cinque minuti, controllando comunque la scadenza a ogni recupero. La durata minima residua è 180 secondi.

CLI con output JSON e codici di uscita:

```powershell
pwsh -NoProfile -File ./scripts/Invoke-GraphAutomation.ps1 -Action Accounts
pwsh -NoProfile -File ./scripts/Invoke-GraphAutomation.ps1 `
    -Action Request -ProfileId '<ProfileId>' -Path '/v1.0/me' -CacheOnly
```

`0`: successo; `2`: accesso/token/identità/permessi da sistemare; `3`: configurazione/cache/input; `4`: rete o limitazione Graph; `5`: altro errore. Gli errori contengono un codice, mai il bearer. Le risposte Graph possono contenere dati personali richiesti dalla tua automazione: gestiscine l'output di conseguenza.

Vedi [automazioni ed esempi](docs/automation.md) per Utilità di pianificazione, richieste di scrittura, Python e uso diretto di `SecureString`.

## Conservazione e limiti

Il comportamento iniziale è **solo memoria**. La persistenza facoltativa usa **Windows DPAPI CurrentUser**: token e vincoli del profilo sono cifrati insieme sotto `%LOCALAPPDATA%\GraphExplorerTokenManager`. I file JSON contengono solo metadati del profilo. Non spostare la cache su OneDrive o nel repository; non è una configurazione credenziali portabile.

**Cancella token** elimina il token dalla sessione del programma e dal file protetto. **Rimuovi profilo** elimina anche i metadati. Le copie già ottenute da altri processi, gli appunti e la sessione Microsoft non vengono revocati. Non viene conservato alcun refresh token.

Il recupero di un nuovo token richiede una sessione Graph Explorer utilizzabile, un desktop interattivo e controlli UI compatibili. Password, MFA, consensi e policy Microsoft restano applicabili. **Questo percorso non garantisce esecuzioni perpetue senza intervento o rinnovo mentre Windows è disconnesso.** Una cache valida può funzionare senza browser, fino alla scadenza o revoca.

Sono supportati token JWT leggibili e account delegati nel cloud globale. La decodifica JWT controlla preliminarmente audience, tenant, utente, scope e scadenza; **non verifica la firma**. Microsoft Graph valida lo stesso bearer durante `/me`. Questo non prova il diritto di eseguire ogni altra API.

Il tool non legge cookie, password salvate, database o cronologia del browser. I processi dello stesso utente Windows possono usare DPAPI: non è una difesa da software malevolo eseguito con la tua identità. La cronologia e la sincronizzazione degli appunti possono conservare copie esplicite. Vedi [SECURITY.md](SECURITY.md).

## Aggiornamento dalla versione 1

Le API `New-GraphExplorerProfile`, `Connect-GraphExplorerToken`, `Get-GraphExplorerToken`, `Get-GraphExplorerTokenInfo` e `Clear-GraphExplorerToken`, e la CLI `Invoke-TokenManager.ps1`, restano disponibili con la cache in memoria originale. I vecchi `profile.local.json` non vengono importati automaticamente: usa il nuovo riconoscimento per creare un account nominato e ottenere un `ProfileId`.

## Verifica e build

```powershell
pwsh -NoProfile -File ./scripts/Test.ps1
pwsh -NoProfile -File ./scripts/Build-Release.ps1
```

Test sintetici per autenticazione, HTTP, origini, profili, cache e retry; DPAPI reale e recupero da un processo PowerShell separato; controlli GUI, sintassi e manifest. Nessun test offline usa account reali o rete. Build e CI producono ZIP e SHA-256 senza dati locali. Il [resoconto dei collaudi](docs/testing.md) distingue le prove automatiche da quelle eseguite sul PC.

Riferimenti: [Graph Explorer e access token](https://learn.microsoft.com/en-us/graph/graph-explorer/graph-explorer-features), [access token Microsoft](https://learn.microsoft.com/en-us/entra/identity-platform/access-tokens), [Windows DPAPI CurrentUser](https://learn.microsoft.com/en-us/dotnet/api/system.security.cryptography.dataprotectionscope).

Progetto indipendente da Microsoft. Licenza [MIT](LICENSE).
