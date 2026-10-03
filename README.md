# LingoMend

> **The goal is to need us less.**

Write what you can. Learn what you can't.

LingoMend is a lightweight macOS English expression companion for non-native
speakers. Keep your existing input method, leave Chinese placeholders while
writing English, and accept a short candidate near the caret. Explanations
open only when you choose to learn, not before every edit.

## Status: Stage 1 experience build

The local companion interaction is implemented. This is an early experience
build, not a production release:

- Native input experience editor; no Accessibility permission required.
- Non-activating, caret-adjacent candidates and deliberate keyboard acceptance.
- Optional, allowlisted AX notification observation for TextEdit and Safari.
- Only the fixed example `轻载条件下 → under light-load conditions` works at
  this stage; real-provider settings are disabled and the app does not network.
- Cross-app acceptance is experimental and off by default. External IME
  composition, notification coverage, native undo and app compatibility remain
  unverified. The local editor uses native text editing/undo.
- Model adapter, text diff and local learning-data foundations are present,
  but are not yet a complete model/learning product.

TypeTide is an isolated MIT reference, not the product base. LingoMend owns its
Smart Scope and companion UX. Private validation notes are not published.

## Try it locally

Requires macOS 14+ and complete Xcode with its toolchain selected.

```sh
swift test
sh Scripts/build-local-app.sh
```

Quit any old LingoMend process from its LM menu, open `.build/LingoMend.app`,
then choose **LM → 打开输入体验**.

Pause after `This works 轻载条件下.` to see a candidate. **Control-Option-Return**
accepts it; **Control-Option-K** opens learning; **Control-Option-Period**
dismisses it. Ordinary Tab/Return and IME composition keys are not intercepted.

See the [Stage 1 experience steps](docs/stage-1-experience.md) for local and
optional TextEdit testing. Rebuilt ad-hoc signed apps can require manual
Accessibility reauthorization; no development certificate is included.

## Principles and architecture

- Users write first; candidates fill a small expression gap, not an entire draft.
- Preserve correct English and keep broad rewrites out of inline acceptance.
- Observation is off by default and scoped to apps explicitly enabled by users.
- Swift 6, AppKit and SwiftUI; no Electron, bundled large model or cloud relay.
- No key logging, clipboard-based capture, or full-draft logs/analytics.
- Local expression cards live under Application Support/LingoMend; full drafts
  are not retained. Saving is voluntary; assisted reuse is not mastery evidence.
- Future model credentials use the OS Keychain; model/settings values are not secrets.

## Delivery

See the [staged development plan](docs/development-stages.md). Each stage ends
with tests/build, Conventional Commits and a normal remote push, a report and
user test steps. Work stops for feedback before proceeding to the next stage.

Next: real suggestions and safe acceptance; then on-demand learning and reuse
evidence; then performance, compatibility and release packaging.

## License

MIT. Any reused third-party code must retain its notices and be recorded in
`THIRD_PARTY_NOTICES.md`.
