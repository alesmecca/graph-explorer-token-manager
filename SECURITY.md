# Security policy

Applies to Graph Explorer Token Manager 1.x. This independent interactive helper is intended for your own authorized Graph Explorer session. It is not an unattended authentication service or credential vault.

## Trust boundaries

Expected tenant and account object IDs are mandatory. JWT inspection is preliminary metadata processing, not signature validation. A fixed HTTPS Graph `/me` request must succeed and return the expected user ID before caching. Redirects are disabled. Opaque tokens and national clouds are unsupported.

The tool trusts Windows, PowerShell, Edge and your interactive desktop. It cannot protect against malicious same-user processes, compromised UI providers, debuggers, administrators or memory dumps. A browser origin check and a private worker marker are safeguards against accidental misuse, not isolation from malicious local software. The worker's redirected output contains the token and must never be redirected to a file or invoked directly.

## Credential handling

Tokens are stored only in process memory. Public token retrieval returns an independent read-only `SecureString`. Managed plaintext temporarily exists for UI extraction, JSON transport, HTTP and explicit clipboard copy; .NET cannot guarantee zeroing every immutable string. The application writes no token logs or credential files. Host-wide transcripts, tracing, crash collection and endpoint monitoring are outside that guarantee.

Login, MFA, consent and account selection remain manual. No refresh token is read or retained. Cache clearing does not revoke Microsoft sessions. `/me` proves acceptance at verification time, not future validity or authorization to every Graph API.

Clipboard copy is explicit. Clipboard history, synchronization and other applications may retain the token. The clipboard is not automatically cleared. Profile files contain organizational identity and scope metadata, so avoid publishing local profiles even though they contain no credentials.

## Reporting vulnerabilities

Use [GitHub private vulnerability reporting](https://github.com/alesmecca/graph-explorer-token-manager/security/advisories/new) when enabled. If unavailable, open an issue asking only for a private contact channel. Do not publish exploit details before establishing that channel, or include tokens, cookies, Authorization headers, organizational profiles or unredacted dumps.

Provide the affected version, runtime versions and sanitized reproduction steps. If a token was exposed, remove published copies and follow your organization's identity incident response procedure. Contact your tenant administrator regarding containment and session revocation.
