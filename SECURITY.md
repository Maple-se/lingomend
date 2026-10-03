# Security Policy

LingoMend is pre-release software. Do not use current development builds with passwords, secrets, private messages, or confidential documents.

## Reporting

Please avoid publishing sensitive vulnerability details in a public issue. Until a dedicated security contact is established, open a minimal issue requesting a private reporting channel.

## Security boundaries

- Text is processed only after an explicit user trigger by default.
- Companion observation is off by default and requires an explicit application
  allowlist. It uses Accessibility notifications, not global key recording.
- Networking is off by default. Enabling the model service and saving settings
  authorizes requests from the native experience editor and explicitly allowlisted
  apps. With companion observation enabled, those requests can be automatic after
  a quiet interval. The allowlist is not a per-document or per-site consent boundary.
- The settings connection-test button separately authorizes one synthetic-text
  request, even with normal networking disabled; it never captures another app.
- DeepSeek receives the placeholder, left/right scope snippets (each capped at
  200 UTF-16 units), writing context/level and, only for explicit explanation,
  the fixed candidate phrase. Learning history and app identities are not sent.
  Short sentences/fields can fit entirely within those context bounds.
- Automated model tests use synthetic in-memory responses. No real paid API
  test is implied by a successful build.
- Native secure-field subroles are refused. An allowlisted browser is not a
  per-site permission boundary: all its accessible non-password fields are in
  scope. Sensitive browser sessions should not be allowlisted.
- AX is not a universal IME-composition interface. Cross-app composition,
  notification coverage and native undo remain compatibility work; acceptance
  is experimental and disabled by default.
- API credentials use Keychain and are isolated by the normalized complete
  endpoint. Redirects are refused, cookies/cache are disabled, and HTTP is allowed
  only for loopback development endpoints. Custom endpoints receive their own
  explicitly supplied key and text; OpenAI-compatible does not imply trusted.
- No promise of zero server retention is made. A provider's own terms, privacy
  settings and infrastructure govern the data after transmission.
- Response validation constrains format, size and local edit boundaries, not
  semantic truth. Prompt injection is treated as untrusted input; model output
  cannot choose edit ranges, invoke tools or execute commands.
- Short-lived memory caching is bounded to eight expression requests; there is
  no persistent draft cache. Credentials remain in memory while the enabled
  service session exists and in Keychain until explicitly removed.
- Full source text must not be written to logs or analytics.
- A replacement must be abandoned if focus, target element, range, or source text changed.
