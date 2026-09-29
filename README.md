# LingoMend

> Write what you can. Learn what you can't.

LingoMend is a lightweight, system-wide AI English expression coach for non-native speakers. Write as much as you can in English, leave temporary gaps in your native language, and learn from the smallest useful correction.

> **The goal is to need us less.**

## Status

The narrow Stage 0 system-integration decision is complete; macOS MVP work
has begun. TypeTide is an isolated MIT-licensed reference, not the product
base; LingoMend owns Smart Scope, safe replacement, and learning behavior.

Detailed TypeTide validation notes are kept locally and are not published.
The [targeted-reuse decision](docs/adr/0002-targeted-reuse-and-mvp-gate.md)
uses a small representative-app gate; ten-app coverage is a later
compatibility task.
The [MVP slice plan](docs/mvp-slice-plan.md) records the next implementation
and release checks.

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

1. Build LingoMend's macOS capture/review/replace loop with its own Smart Scope and safety gate.
2. Add expression memory after the main input flow is reliable.
3. Expand compatibility testing to the original ten-app matrix where apps are available.

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
