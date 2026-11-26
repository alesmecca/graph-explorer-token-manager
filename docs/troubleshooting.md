# Risoluzione dei problemi

Non inserire token o cookie nelle segnalazioni. I codici restituiti non contengono il token.

| Codice / sintomo | Intervento |
| --- | --- |
| Il launcher non parte | Verificare `pwsh --version` (7.4+). Per leggere l'errore: `pwsh -NoProfile -STA -File ./scripts/Start-TokenManager.ps1`. Rispettare le policy aziendali di esecuzione. |
| `invalid_profile`, `invalid_profile_file` | Nella v2 controllare nome e scope del profilo e ripetere Rileva account. I GUID manuali servono solo alle API legacy. |
| `browser_unavailable` | Avviare Microsoft Edge nella stessa sessione Windows. |
| `graph_explorer_tab_not_found` | Selezionare manualmente Graph Explorer in una finestra Edge non minimizzata; lingua browser italiana o inglese. |
| `browser_origin_not_verified` | Usare il sito ufficiale HTTPS `developer.microsoft.com/.../graph/graph-explorer`; non proxy o pagine simili. |
| `ambiguous_explorer_windows` | Premere Cerca finestre e scegliere quella desiderata; per un profilo esistente usare Salva impostazioni. |
| `token_not_visible` | Completare login e selezionare Access token. Provare l'interazione opzionale o l'inserimento manuale nascosto. |
| `ambiguous_token_controls` | Lasciare visibile soltanto il token desiderato, evitando altri token nei pannelli risposta. |
| `desktop_in_use` | Riprovare e lasciare mouse e tastiera inattivi almeno tre secondi. |
| `control_not_actionable`, `token_worker_failed` | Potenziale cambiamento UI, policy o provider UIA. Usare Incolla token e riportare versioni browser/runtime. |
| `browser_timeout` | Il worker viene terminato. Riprovare o usare input manuale; il modulo consente `-TimeoutSeconds` da 5 a 120. |
| `browser_confirmation_required` | Edge mostra Ricarica sito. Scegliere Ricarica o Annulla nel browser, poi riprovare. Il tool interrompe l'attesa senza confermare automaticamente modifiche non salvate. |
| `wrong_tenant`, `wrong_account` | Confrontare profilo e account realmente autenticato. Non cambiare il profilo soltanto per aggirare il controllo. |
| `wrong_audience` | Usare un token emesso per Microsoft Graph. |
| `required_scopes_missing` | Concedere i permessi delegati necessari tramite Modify permissions e acquisire un token aggiornato. `User.Read` è obbligatorio. |
| `token_expired`, `token_not_yet_valid` | Usare Aggiorna pagina e rileggi token o Accedi / scegli account. Controllare l'orologio Windows. Un refresh non garantisce un token nuovo. |
| `unsupported_token_format` | Token opaco/non JWT: formato non supportato; non tentare di modificarlo. |
| `graph_unauthorized` | Graph restituisce 401: ripetere login e acquisizione. |
| `graph_forbidden` | Graph restituisce 403: controllare User.Read, consenso e policy del tenant. |
| `graph_throttled` | Graph restituisce 429: attendere prima di riprovare. Nessun retry automatico. |
| `graph_unavailable` | Verificare rete, proxy e accesso a `graph.microsoft.com`; timeout HTTP 15 secondi. Nessun redirect consentito. |
| `graph_identity_mismatch` | Graph non restituisce l'Object ID atteso oppure la risposta non ha il formato previsto. |
| `token_not_connected` | Collegarsi nel medesimo processo PowerShell. Ogni nuova CLI ha memoria separata. |
| `interaction_required` | La cache non basta: usare Accedi / scegli account, completare eventuali richieste Microsoft e recuperare il token. CacheOnly non usa il browser. |
| `cache_corrupt` | Cache danneggiata, copiata da un altro profilo/utente o non decifrabile. Recupera da Edge sostituisce la cache dopo la verifica; Cancella token la elimina. |
| `cache_unavailable` | Verificare permessi e disponibilità della cartella locale. Il token non è stato salvato in modo riutilizzabile. |
| `profile_busy` | Un altro processo usa il profilo; il lock attende al massimo cinque secondi. Riprovare dopo la sua conclusione. |
| `profile_store_invalid` | Individuare il JSON locale danneggiato in LOCALAPPDATA/GraphExplorerTokenManager, conservarne una copia privata e ricreare il profilo. Non pubblicarlo. |
| `discovery_expired` | Ripetere il rilevamento e confermare entro cinque minuti. |
| `invalid_graph_path` | Usare un percorso /v1.0/... o /beta/... oppure un URL HTTPS del solo host graph.microsoft.com. |
| La scelta account non compare nel tool | Il tool riprende un selettore Graph Explorer già aperto e mostra la propria scelta in primo piano. Se Microsoft usa un flusso diverso, scegliere nel browser e usare Rileva account. |

Ogni lettura browser ha un timeout di 30 secondi, più 2 di tolleranza; il controllo identità HTTP ha 15 secondi e le richieste applicative 30. Un recupero con refresh può effettuare due letture. La GUI non blocca il thread grafico: Annulla rilevamento scarta il risultato e ripulisce il candidato appena termina il worker. La chiusura durante un'operazione viene completata al termine del lavoro già avviato.

Dopo Sign in la GUI attende il completamento della sessione e riprova il rilevamento per 45 secondi; l'ultimo worker può completarsi entro il proprio timeout. Password o MFA che richiedono più tempo possono essere completati nel browser, seguiti da Rileva account.

`Connect-GraphExplorerToken -Force` evita il riuso della cache. Una nuova verifica fallita elimina il precedente token del medesimo profilo. Gli altri profili rimangono separati. Dopo la copia, gestire anche cronologia e sincronizzazione degli appunti Windows: chiudere il programma non cancella né revoca le copie.
