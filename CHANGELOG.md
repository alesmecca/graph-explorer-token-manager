# Changelog

## 1.0.0 — 2026-11-26

- Prima versione autonoma: GUI Windows, CLI e modulo PowerShell 7.4+.
- Profili espliciti per tenant, utente, scope e validità residua.
- Acquisizione Edge passiva con interazione facoltativa; input manuale protetto.
- Worker isolato con timeout, verifica origine e nessuna automazione di login/MFA/consenso.
- Controlli preliminari JWT e conferma identità attraverso Graph `/me` senza redirect.
- Cache soltanto in memoria, SecureString copiati e nessun bearer negli output ordinari.
- Test offline, GitHub Actions, ZIP versionato e SHA-256.
