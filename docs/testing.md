# Verifiche

Eseguire `pwsh -NoProfile -File ./scripts/Test.ps1` dalla radice. Non sono richiesti moduli esterni.

## Copertura automatica offline

- Parsing di tutti i file PowerShell e controllo del manifest.
- Profili, audience, tenant, account, scope esatti, scadenza, margine, nbf, formati non validi e claim duplicati.
- Cache separata per profilo, copie SecureString indipendenti, cancellazione e nessun riuso dopo errori.
- Canary sintetico assente da output, metadati e rappresentazioni degli errori.
- Client HTTP con handler simulato: metodo e URL fissi, bearer, redirect disabilitati, risposte 200/204/302/401/403/429/500 e guasto rete.
- Origini consentite e rifiutate; guardia del worker, senza accesso al desktop.
- Costruzione di tutti i controlli della GUI senza visualizzare finestre.
- Primo avvio vuoto, candidato non salvato prima della conferma, annullamento e scadenza della conferma.
- DPAPI Windows reale, blob corrotto/coperto da un altro profilo, modifica dell'identità esterna, scritture atomiche e lock con timeout.
- Riutilizzo del token sintetico protetto da un nuovo processo PowerShell, con verifica Graph simulata e nessuna lettura browser.
- CacheOnly, disattivazione persistenza, cambio scope, cancellazione, rifiuto dell'account sbagliato e refresh limitato.
- URI Graph, redirect, 401 con token uguale/diverso, mancato replay di scritture, invalidazione del bearer rifiutato.
- Stato GUI asincrono: controlli durante il lavoro, conferma dell'identità, risultato tardivo dopo annullamento, errore e nuovo tentativo nello stesso runspace.

I token dei test sono fittizi e non hanno una firma valida. Nessun test offline contatta Graph o legge il browser. I test non certificano selettori UIA su ogni build di Edge.

## Collaudo delle API legacy

1. Preparare un profilo locale per il proprio account e aprire il sito ufficiale in Edge.
2. Completare login, MFA e consenso `User.Read`; selezionare Access token.
3. Avviare Connect senza AllowInteraction: deve leggere senza cambiare scheda e mostrare solo metadati dopo `/me`.
4. Provare un Object ID diverso: il risultato deve essere `wrong_account` e la cache del profilo deve rimanere vuota.
5. Verificare recupero, cancellazione e invalidazione al cambio identità. Non includere token negli screenshot.
6. Selezionare un altro pannello della pagina: il passivo deve fallire senza selezionare nulla. Con AllowInteraction e desktop inattivo può selezionare Access token.
7. Completare una prova separata del campo manuale, senza salvare il token in file o cronologia shell.

Registrare soltanto versione runtime/browser, codice esito e data. Nessun access token, profilo reale o screenshot del pannello token deve entrare nel repository.

## Collaudo della versione 2

Il 26 novembre 2026, sullo stesso PC Windows/Edge della prima release, sono riusciti:

- Avvio Sign in sulla pagina Graph Explorer verificata e selezione dell'account Microsoft già presente e corrispondente alla configurazione precedente; l'accesso si è completato senza inserire nuove credenziali.
- Riconoscimento dell'identità da Graph Explorer senza digitare GUID, verifica reale `/me` e conferma del profilo locale.
- Salvataggio DPAPI, chiusura del processo e successiva richiesta reale Graph da un nuovo processo in modalità **CacheOnly**, senza accesso al browser.
- Invocazione del controllo Reload di Edge, selezione del pannello e rilettura/verifica del token. **La scadenza non è avanzata in questa prova**: dimostra la rilettura, non un rinnovo del token scaduto.
- GUI reale: selettore account aperto sopra Edge, selezione dell'account atteso, completamento automatico del login, identità rilevata, annullamento della conferma e successiva richiesta Graph con il profilo salvato. Il percorso è riuscito anche dopo una ricarica che aveva richiesto un nuovo Sign in.

La suite v2 comprende **116 casi backend** (33 core, 11 HTTP, 26 origini/applicazione, 7 classificazioni di conferme native, una guardia worker, 38 account/cache/automazioni), oltre a sintassi, manifest, compilazione dell'adattatore UIA e controlli di stato GUI, inclusi caricamento profili e selezione finestre. DPAPI è reale; HTTP e identità nei test automatici sono sintetici. La separazione DPAPI fra utenti Windows differenti non è stata collaudata con un secondo utente.

La conferma nativa Ricarica sito è stata segnalata durante il collaudo. Il codice ora separa l'invocazione del reload dal rilevamento dei dialoghi, seguendo il comportamento documentato di [InvokePattern.Invoke](https://learn.microsoft.com/en-us/dotnet/api/system.windows.automation.invokepattern.invoke). La classificazione è coperta da casi sintetici; il dialogo non si è ripresentato nella ripetizione finale, quindi non viene dichiarata una verifica reale di entrambi i suoi pulsanti.

Non sono certificati un nuovo consenso amministrativo, MFA imposto da tutte le policy, due account reali contemporanei, il rinnovo dopo la scadenza, la continuità di job con Windows disconnesso o ogni versione/lingua del browser. Questi limiti non sono coperti da mock e non vengono dichiarati superati.

## Collaudo della prima release

Il 26 novembre 2026 il recupero **passivo reale** e la successiva verifica `GET /me` sono riusciti su Windows build 26200, PowerShell 7.6.10 e Microsoft Edge 158.0.4370.33 con interfaccia italiana. Il risultato conferma la lettura dalla pagina visibile e l'identità configurata. Il token è rimasto in memoria ed è stato eliminato dalla cache a fine prova.

Questa prova non certifica tutte le lingue, versioni di Edge, policy dei tenant o la copia negli appunti. I 57 casi automatici (33 core, 11 HTTP, 12 origini e una guardia worker) restano distinti dal test su account reale; il runner controlla inoltre manifest, sintassi e costruzione GUI.
