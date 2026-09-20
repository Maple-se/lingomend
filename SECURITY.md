# Security Policy

LingoMend is pre-release software. Do not use current development builds with passwords, secrets, private messages, or confidential documents.

## Reporting

Please avoid publishing sensitive vulnerability details in a public issue. Until a dedicated security contact is established, open a minimal issue requesting a private reporting channel.

## Security boundaries

- Text is processed only after an explicit user trigger by default.
- API credentials must use the operating system credential store.
- Full source text must not be written to logs or analytics.
- A replacement must be abandoned if focus, target element, range, or source text changed.

