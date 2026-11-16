# Security Policy

## Supported versions

Security fixes are released for the latest minor version of CcinnClickHouse.

| Version | Supported |
|---|---|
| 1.0.x | ✅ |

## Reporting a vulnerability

Please **do not open a public issue** for security problems.

Report vulnerabilities privately through GitHub's [private vulnerability reporting](https://github.com/whiteCcinn/ccinnclickhouse/security/advisories/new). Include:

- a description of the issue and its impact,
- steps to reproduce (ClickHouse version, connection options, sample data if relevant),
- any suggested fix.

You can expect an acknowledgement within a few days. Once a fix is available, we will publish a release and an advisory crediting the reporter (unless you prefer to remain anonymous).

## Scope and design notes

- Passwords and SSH secrets are stored in the macOS Keychain; saved profiles on disk (0600) never contain them. Credentials travel in the `Authorization` header, never in URLs; redirects are not followed.
- HTTPS uses the system trust store, optionally extended with a private CA per connection. Through an SSH tunnel, certificates are still verified against the server's real host name. "Skip certificate verification" exists for test setups and is clearly marked.
- Read-only connections and read-only AI access are enforced by ClickHouse itself (`readonly=1` on every request, with `getSetting('readonly')` verified on the actual request path when connecting — a proxy that drops the parameter, such as chproxy, makes the connection fail closed) and, in addition, by the app's read-only guard, which refuses anything that is not clearly a read, any function that reaches outside ClickHouse and any per-query `SETTINGS` before it is sent. A bypass of either layer is in scope.
- **Recommended deployment for AI access:** a dedicated ClickHouse user whose settings profile is read-only and who holds `SELECT` grants only (no `SOURCES`/`URL`/`FILE`/`REMOTE`/`S3` grants). The server profile — not a URL parameter — then enforces read-only access, so it holds behind proxies that drop parameters (chproxy) and independently of the app. The README and Settings → MCP give the SQL.
- Each MCP tool call is a separate stateless request without a server session, so `SET`, `USE` and temporary tables never carry from one call into the next.
- SQL written to the query history and the MCP audit log (`mcp-audit.jsonl`, 0600) is redacted: `IDENTIFIED … BY`, `PASSWORD`, credential-like settings and named-collection values, credential arguments of table functions/engines (`mysql`, `postgresql`, `remote`, `s3`, …) and `user:password@` in URLs become `***`.
- SSH tunnels use the system `/usr/bin/ssh` with `StrictHostKeyChecking=accept-new` (changed host keys are rejected). Secrets reach `ssh` through a short-lived 0600 file, never the environment or argv; key mode is public-key only and agent mode never sends a stored secret.
- `CCINNCLICKHOUSE_TEST_PASSWORD_<PROFILE-UUID>` is a **test-only** password source for the MCP subprocess tests; do not use it outside test environments.
- Statements built by the app (metadata, `KILL QUERY`, `KILL MUTATION`, `SYSTEM RELOAD DICTIONARY`) quote identifiers and literals; issues that allow injecting SQL through object names are considered vulnerabilities.
- Update checks contact only `api.github.com` and `github.com`, send no personal data (the User-Agent is `CcinnClickHouse/<version>`), and run at most once a day unless you check manually. A downloaded disk image is accepted only from this repository's download URL for the same release tag, at the size the release lists, and with the SHA-256 published in that release's `SHA256SUMS.txt`. The checksum guards against corruption and truncation, not against a compromised GitHub release; authenticity relies on HTTPS to github.com. The app never replaces itself; you drag the new version into Applications.
