# Contributing

LingoMend is a native macOS English-expression companion. Keep changes focused and discuss large architectural changes before implementation. Follow [AGENTS.md](AGENTS.md) for project rules.

- Preserve the author's meaning and require explicit acceptance before editing.
- Keep platform integration separate from coaching and learning. Record third-party code in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
- Never commit credentials, real drafts, runtime logs, private reviews, internal requirements or validation records.
- Use synthetic data for tests. Default tests must not call a paid service.
- Keep user-facing documentation and version metadata aligned with shipped behavior.

```sh
swift test --disable-sandbox
sh Scripts/build-local-app.sh development
```

Review staged changes before committing. Use Conventional Commits and push only with authorization.
