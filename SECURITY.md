# Security Policy

LingoMend is pre-release software. Do not use current development builds with passwords, secrets, private messages, or confidential documents.

## Reporting

Please avoid publishing sensitive vulnerability details in a public issue. Until a dedicated security contact is established, open a minimal issue requesting a private reporting channel.

## Security boundaries

- Text is processed only after an explicit user trigger by default.
- Companion observation is off by default and requires an explicit application
  allowlist. It uses Accessibility notifications, not global key recording.
- Stage 1 app builds use local fixed suggestions only; network configuration is
  disabled. Model adapter tests use synthetic in-memory responses.
- Native secure-field subroles are refused. An allowlisted browser is not a
  per-site permission boundary: all its accessible non-password fields are in
  scope. Sensitive browser sessions should not be allowlisted.
- AX is not a universal IME-composition interface. Cross-app composition,
  notification coverage and native undo remain compatibility work; acceptance
  is experimental and disabled by default.
- API credentials must use the operating system credential store.
- Full source text must not be written to logs or analytics.
- A replacement must be abandoned if focus, target element, range, or source text changed.
