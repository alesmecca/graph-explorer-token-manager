# Changelog

## 2.0.0 — 2026-11-26

- Primo utilizzo senza GUID o account preconfigurati: avvio Sign in, scelta degli account proposti da Microsoft e riconoscimento verificato con `/me`.
- Profili nominati, conferma dell'identità, scelta della finestra Edge e accesso InPrivate.
- Salvataggio token facoltativo con Windows DPAPI CurrentUser per script e processi separati; cancellazione, lock fra sessioni e scritture atomiche.
- Wrapper Graph, CLI JSON con exit code, modalità CacheOnly, esportazione script e guida alle attività pianificate.
- Rilettura/aggiornamento pagina autorizzati, timeout, verifica dell'account e retry limitato ai GET/HEAD con token diverso.
- Scelta account in primo piano, ripresa del selettore Microsoft già aperto e attesa del completamento Sign in. Ricarica asincrona con rilevamento delle conferme native Edge.
- Nuovi test di cache, DPAPI reale, riuso fra processi, account sbagliato, origini login, retry e stato asincrono GUI.
- API in memoria della versione 1 mantenute. Nessuna app, certificato o client secret richiesti.

## 1.0.0 — 2026-11-26

- Prima versione autonoma: GUI Windows, CLI e modulo PowerShell 7.4+.
- Profili espliciti per tenant, utente, scope e validità residua.
- Acquisizione Edge passiva con interazione facoltativa; input manuale protetto.
- Worker isolato con timeout, verifica origine e nessuna automazione di login/MFA/consenso.
- Controlli preliminari JWT e conferma identità attraverso Graph `/me` senza redirect.
- Cache soltanto in memoria, SecureString copiati e nessun bearer negli output ordinari.
- Test offline, GitHub Actions, ZIP versionato e SHA-256.
