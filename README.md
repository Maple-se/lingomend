# LingoMend

> Write what you can. Learn what you can't.

LingoMend is a lightweight, system-wide AI English expression coach for non-native speakers. Write as much as you can in English, leave temporary gaps in your native language, and learn from the smallest useful correction.

> **The goal is to need us less.**

## Status

LingoMend is moving from a narrow Stage 0 system-integration spike into its
macOS MVP. TypeTide is an isolated MIT-licensed reference, not the product
base; LingoMend owns Smart Scope, safe replacement, and learning behavior.

The isolated [TypeTide validation log](docs/research/typetide-validation-log.md)
records the pinned upstream commit and observed behavior. The
[targeted-reuse decision](docs/adr/0002-targeted-reuse-and-mvp-gate.md) uses a
small representative-app gate; ten-app coverage is a later compatibility task.

No production-ready application is available yet.

## Product principles

- The user writes first; AI helps second.
- A native-language placeholder should not interrupt thought.
- Preserve correct user-written English and make the minimum necessary correction.
- Show what changed before replacing text.
- Reward growing independence, not growing AI usage.
- Process only user-triggered text by default.

## Initial technical direction

- macOS-first
- Swift 6 with SwiftUI and AppKit
- Accessibility-based Smart Scope with explicit user trigger
- Local-first learning data
- OpenAI-compatible and local-model provider abstraction
- No Electron or always-on cloud service

## Repository roadmap

1. Complete representative-app and safety checks on the isolated TypeTide experiment.
2. Build LingoMend's macOS capture/review/replace loop with its own Smart Scope and safety gate.
3. Add expression memory after the main input flow is reliable.
4. Expand compatibility testing to the original ten-app matrix where apps are available.

## Development requirements

- macOS 14 or later
- A complete Xcode installation with a matching macOS SDK and Swift toolchain

After selecting the Xcode developer directory, run:

```sh
swift build
swift test
```

## License

MIT. Third-party code, if introduced, will retain its original notices and be recorded in `THIRD_PARTY_NOTICES.md`.
