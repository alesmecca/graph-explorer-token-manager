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

I token dei test sono fittizi e non hanno una firma valida. Nessun test offline contatta Graph o legge il browser. I test non certificano selettori UIA su ogni build di Edge.

## Collaudo interattivo

1. Preparare un profilo locale per il proprio account e aprire il sito ufficiale in Edge.
2. Completare login, MFA e consenso `User.Read`; selezionare Access token.
3. Avviare Connect senza AllowInteraction: deve leggere senza cambiare scheda e mostrare solo metadati dopo `/me`.
4. Provare un Object ID diverso: il risultato deve essere `wrong_account` e la cache del profilo deve rimanere vuota.
5. Nella GUI verificare import/export del profilo, recupero, disponibilità di Copia token, cancellazione e invalidazione al cambio identità. La copia è opzionale e non va inclusa negli screenshot.
6. Selezionare un altro pannello della pagina: il passivo deve fallire senza selezionare nulla. Con AllowInteraction e desktop inattivo può selezionare Access token.
7. Completare una prova separata del campo manuale, senza salvare il token in file o cronologia shell.

Registrare soltanto versione runtime/browser, codice esito e data. Nessun access token, profilo reale o screenshot del pannello token deve entrare nel repository.

## Collaudo della prima release

Il 26 novembre 2026 il recupero **passivo reale** e la successiva verifica `GET /me` sono riusciti su Windows build 26200, PowerShell 7.6.10 e Microsoft Edge 158.0.4370.33 con interfaccia italiana. Il risultato conferma la lettura dalla pagina visibile e l'identità configurata. Il token è rimasto in memoria ed è stato eliminato dalla cache a fine prova.

Questa prova non certifica tutte le lingue, versioni di Edge, policy dei tenant o la copia negli appunti. I 57 casi automatici (33 core, 11 HTTP, 12 origini e una guardia worker) restano distinti dal test su account reale; il runner controlla inoltre manifest, sintassi e costruzione GUI.
