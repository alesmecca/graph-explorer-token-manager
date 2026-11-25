# Contribuire

Usare PowerShell 7.4+ su Windows. Eseguire `pwsh -NoProfile -File ./scripts/Test.ps1` prima di una pull request. I test devono restare offline: usare fixture sintetiche e handler HTTP simulati, senza tenant, browser reale o credenziali.

Per modifiche UIA indicare versione di Edge, lingua e controlli verificati. Non aggiungere fallback che leggano cookie, profili browser, credenziali, appunti o token di account non esplicitamente selezionati. Non introdurre bypass della verifica identità o output in chiaro del token.

Aggiornare changelog e documentazione quando cambia il comportamento pubblico. Non includere file `*.local.json`, log, token o identificativi aziendali nelle PR. Segnalare vulnerabilità secondo [SECURITY.md](SECURITY.md).
