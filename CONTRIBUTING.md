# Contributing

LingoMend is in an early validation phase. Before opening a large pull request, please start with an issue describing the user problem, platform impact, and privacy implications.

## Principles

- Never log selected text, prompts, model responses, or credentials.
- Preserve undo behavior and never overwrite text when focus or source content changed.
- Keep platform integration separate from coaching and learning logic.
- Add deterministic tests for behavior that does not require a live model.
- Record all copied or adapted third-party code in `THIRD_PARTY_NOTICES.md`.

## Local checks

```sh
swift build
swift test
```

