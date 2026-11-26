# Security policy

Applies to Graph Explorer Token Manager 2.x. This helper uses your authorized Graph Explorer session. It does not require an app registration and is not an unattended authentication service.

## Identity and browser boundaries

Discovery derives tenant/object IDs from preliminary JWT metadata, checks audience, expiry and scopes, and verifies the exact bearer against HTTPS Microsoft Graph `/me`. Confirmation is required before creating a named profile. Existing profiles never silently change identity. JWT decoding is not signature validation; Graph validates the credential. Opaque tokens and national clouds are unsupported.

Browser extraction reads only visible controls of an origin-verified Graph Explorer document. It does not read browser cookies, credential stores or hidden tabs. Optional page selection/reload operates on verified controls. Sign-in only invokes the Graph Explorer sign-in button, then lists account choices from a newly opened Microsoft login window. Selecting an account rechecks that the window belongs to Edge and its address is HTTPS `login.microsoftonline.com` or `login.live.com`. It never fills passwords, approves MFA or grants consent. Unsupported flows remain in Microsoft's browser UI.

The adapter runs in a bounded child process. Its private redirected output can contain plaintext tokens and must never be logged or invoked directly. The marker guarding this worker is not isolation from malicious local programs. UIA and Windows are trusted; a compromised UI provider is outside this protection.

A previously opened sign-in picker is reused only when its verified Microsoft URL includes the [published Graph Explorer client ID](https://github.com/MicrosoftDocs/SupportArticles-docs/blob/main/support/entra/entra-id/governance/verify-first-party-apps-sign-in.md). The tool does not create its own app registration. Missing, duplicate or unrelated client IDs fail this recovery check.

## Memory and optional persistence

Default storage is process memory. Public token retrieval returns an independent read-only `SecureString`; dispose it after use. Temporary plaintext is necessary for UI extraction, JSON transport, HTTP and explicit clipboard copy. Immutable managed strings cannot all be reliably zeroed. No refresh token is read or retained.

Persistence is opt-in per profile. Windows DPAPI **CurrentUser** protects the complete credential payload, including profile ID, identity/scope/margin binding and verification time. Profile-specific entropy prevents copying a blob to another profile. Writes use encrypted temporary files in the same directory and atomic replacement. A bounded exclusive file lock serializes profile mutations across Windows sessions. Plain profile JSON contains identity metadata, not bearer tokens. The default location is local application data, not the repository or a cloud-synchronized folder.

Every restored token is checked against the requested profile and expiry, then verified with Graph before use in a new process. In-process verification can be reused for five minutes, with expiry checked on every retrieval. Clearing cache affects this process and its stored file; already-issued copies in other processes and Microsoft sessions are not revoked. Disabled persistence prevents loading its saved token.

DPAPI does not protect against another process running as the same Windows user, administrators, debuggers, endpoint monitoring or memory dumps. Transcripts, tracing and host-wide crash collection are outside the application's no-token-log guarantee. Clipboard history/synchronization may preserve explicit copies; the clipboard is not automatically cleared.

## Graph requests

The wrapper accepts only the global Graph HTTPS origin on port 443, without userinfo or fragments, and versioned API paths. Redirects are disabled, timeouts and response-size bounds are enforced, and authorization is attached to each request. No caller-supplied authorization header or automatic pagination is supported. GET/HEAD may acquire a different token and retry once after 401; write methods never automatically retry. A 403 is not retried. Authentication errors exclude raw response bodies and inner credential-bearing exceptions. Successful API responses are the caller's requested data and may contain personal information.

## Reporting

Use [GitHub private vulnerability reporting](https://github.com/alesmecca/graph-explorer-token-manager/security/advisories/new). If unavailable, open an issue requesting a private contact channel without exploit details. Include versions and sanitized reproduction steps, never tokens, cookies, authorization headers, real account profiles or unredacted dumps.
