# Risoluzione dei problemi

Non inserire token o cookie nelle segnalazioni. I codici restituiti non contengono il token.

| Codice / sintomo | Intervento |
| --- | --- |
| Il launcher non parte | Verificare `pwsh --version` (7.4+). Per leggere l'errore: `pwsh -NoProfile -STA -File ./scripts/Start-TokenManager.ps1`. Rispettare le policy aziendali di esecuzione. |
| `invalid_profile`, `invalid_profile_file` | Copiare l'esempio e inserire GUID reali. Per guest usare l'Object ID nel tenant di destinazione. La GUI richiede margine 180 secondi. |
| `browser_unavailable` | Avviare Microsoft Edge nella stessa sessione Windows. |
| `graph_explorer_tab_not_found` | Selezionare manualmente Graph Explorer in una finestra Edge non minimizzata; lingua browser italiana o inglese. |
| `browser_origin_not_verified` | Usare il sito ufficiale HTTPS `developer.microsoft.com/.../graph/graph-explorer`; non proxy o pagine simili. |
| `ambiguous_explorer_windows` | Lasciare una sola finestra con Graph Explorer come pagina attiva. |
| `token_not_visible` | Completare login e selezionare Access token. Provare l'interazione opzionale o l'inserimento manuale nascosto. |
| `ambiguous_token_controls` | Lasciare visibile soltanto il token desiderato, evitando altri token nei pannelli risposta. |
| `desktop_in_use` | Riprovare e lasciare mouse e tastiera inattivi almeno tre secondi. |
| `control_not_actionable`, `token_worker_failed` | Potenziale cambiamento UI, policy o provider UIA. Usare Incolla token e riportare versioni browser/runtime. |
| `browser_timeout` | Il worker viene terminato. Riprovare o usare input manuale; il modulo consente `-TimeoutSeconds` da 5 a 120. |
| `wrong_tenant`, `wrong_account` | Confrontare profilo e account realmente autenticato. Non cambiare il profilo soltanto per aggirare il controllo. |
| `wrong_audience` | Usare un token emesso per Microsoft Graph. |
| `required_scopes_missing` | Concedere i permessi delegati necessari tramite Modify permissions e acquisire un token aggiornato. `User.Read` è obbligatorio. |
| `token_expired`, `token_not_yet_valid` | Rinnovare la sessione in Graph Explorer e controllare l'orologio Windows. Il programma non rinnova autonomamente la sessione. |
| `unsupported_token_format` | Token opaco/non JWT: formato non supportato; non tentare di modificarlo. Per integrazioni applicative usare MSAL con app propria. |
| `graph_unauthorized` | Graph restituisce 401: ripetere login e acquisizione. |
| `graph_forbidden` | Graph restituisce 403: controllare User.Read, consenso e policy del tenant. |
| `graph_throttled` | Graph restituisce 429: attendere prima di riprovare. Nessun retry automatico. |
| `graph_unavailable` | Verificare rete, proxy e accesso a `graph.microsoft.com`; timeout HTTP 15 secondi. Nessun redirect consentito. |
| `graph_identity_mismatch` | Graph non restituisce l'Object ID atteso oppure la risposta non ha il formato previsto. |
| `token_not_connected` | Collegarsi nel medesimo processo PowerShell. Ogni nuova CLI ha memoria separata. |

Il timeout browser predefinito è 30 secondi, più 2 secondi di tolleranza del supervisore; il controllo HTTP può richiedere altri 15 secondi. Finché una verifica è attiva, la GUI rimane utilizzabile per diagnostica ma attende la fine del worker prima di chiudersi.

`Connect-GraphExplorerToken -Force` evita il riuso della cache. Una nuova verifica fallita elimina il precedente token del medesimo profilo. Gli altri profili rimangono separati. Dopo la copia, gestire anche cronologia e sincronizzazione degli appunti Windows: chiudere il programma non cancella né revoca le copie.
