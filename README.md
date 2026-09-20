# LingoMend

> Write what you can. Learn what you can't.

LingoMend is a lightweight, system-wide AI English expression coach for non-native speakers. Write as much as you can in English, leave temporary gaps in your native language, and learn from the smallest useful correction.

> **The goal is to need us less.**

## Status

LingoMend is in Stage 0: product validation and system-integration research. The current focus is validating a low-friction macOS workflow and deciding whether to build on the MIT-licensed TypeTide system layer or implement a clean native bridge.

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

1. Validate TypeTide in a disposable technical spike.
2. Establish the system-layer decision gate.
3. Build reusable Coach and Learning cores.
4. Implement the macOS menu-bar shell and Smart Scope.
5. Add expression memory only after the main input flow is reliable.

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
