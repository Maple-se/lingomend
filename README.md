# LingoMend

> **The goal is to need us less.**

Write what you can. Learn what you can't.

LingoMend is a lightweight macOS English expression companion for non-native
speakers. Keep your existing input method, leave Chinese placeholders while
writing English, and accept a short candidate near the caret. Explanations
open only when you choose to learn, not before every edit.

## Status: Stage 2 API experience build (0.2.0)

The local companion interaction is implemented. This is an early experience
build, not a production release:

- Native input experience editor; no Accessibility permission required.
- Non-activating, caret-adjacent candidates and deliberate keyboard acceptance.
- Optional, allowlisted AX notification observation for TextEdit and Safari.
- DeepSeek Chat Completions with a configurable endpoint/model and a BYOK
  credential stored in macOS Keychain. Networking is off by default.
- Short inline candidates and separately requested learning explanations, with
  JSON validation, non-thinking mode, hard deadlines and cancellation.
- Requests include only the Chinese placeholder and up to 200 UTF-16 units on
  each side within its resolved scope, not arbitrary full fields or history.
  A short sentence/field may fit entirely within that bounded context.
- Without networking, only the fixed example
  `轻载条件下 → under light-load conditions` is supported. API failures never
  silently fall back to that example.
- Cross-app acceptance is experimental and off by default. External IME
  composition, notification coverage, native undo and app compatibility remain
  unverified. The local editor uses native text editing/undo.
- Voluntary local expression saving is available in the learning panel. Library,
  independent-use evidence UI and performance/compatibility work remain later stages.

Real paid requests, candidate quality and runtime Keychain/UI behaviour must be
tested by users with their own credentials. Automated tests use synthetic
in-memory responses, not real API keys. This slice supports Chinese expression
gaps; arbitrary English polishing is not yet an automatic inline feature.

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

To use real suggestions, open **LM → 设置**, keep the DeepSeek preset,
enter your key privately, and click **测试连接（合成文本）**. Then enable
**使用配置的模型服务** and save. The explicit test can make one paid request
even while normal networking is disabled. It does not read other apps.

See the [Stage 2 API experience steps](docs/stage-2-api-experience.md) for setup
and a short user-driven test. Rebuilt ad-hoc signed apps can require manual
Accessibility reauthorization; no development certificate is included.

## Principles and architecture

- Users write first; candidates fill a small expression gap, not an entire draft.
- Preserve correct English and keep broad rewrites out of inline acceptance.
- Observation is off by default and scoped to apps explicitly enabled by users.
- Swift 6, AppKit and SwiftUI; no Electron, bundled large model or cloud relay.
- No key logging, clipboard-based capture, or full-draft logs/analytics.
- Local expression cards live under Application Support/LingoMend; full drafts
  are not retained. Saving is voluntary; assisted reuse is not mastery evidence.
- Model credentials use the OS Keychain, isolated by complete normalized endpoint.
  Switching endpoint does not reuse another endpoint's key. No embedded key or relay.
- A successful JSON check is not proof of semantic correctness; users decide
  whether to accept. External service retention is governed by that provider.

## Delivery

See the [staged development plan](docs/development-stages.md). Each stage ends
with tests/build, Conventional Commits and a normal remote push, a report and
user test steps. Work stops for feedback before proceeding to the next stage.

Next: user feedback on real suggestions, latency and native input/undo; remaining
safe-acceptance compatibility; then learning library/reuse evidence and release work.

## License

MIT. Any reused third-party code must retain its notices and be recorded in
`THIRD_PARTY_NOTICES.md`.
