# LingoMend

> **The goal is to need us less.**

Write what you can. Learn what you can't.

LingoMend is a lightweight macOS English expression companion for non-native
speakers. Keep your existing input method, write what you can, and use Chinese
for expression gaps. Ask for help with your current sentence; necessary English
corrections preserve your meaning, opinions and voice. Learning opens on demand.

## Status: TextEdit T1 sentence-advice build (0.3.0)

The current build delivers read-only sentence advice in TextEdit:

- Explicit **Control-Option-L** help; quiet background operation with no automatic generation.
- Local current-sentence boundaries, including common abbreviations, decimals,
  quotations, line breaks and Unicode character offsets.
- Selected fragments use the containing sentence as read-only context; the
  selected fragment remains the edit boundary.
- Non-activating, caret-adjacent previews with original context and edit differences.
- Mixed-language expression help, necessary English corrections, Chinese-to-English
  expression, unchanged feedback and clarification outcomes.
- DeepSeek Chat Completions with a configurable endpoint/model and a BYOK
  credential stored in macOS Keychain. Networking is off by default.
- Requests include one sentence as target/left/right plus an intent hint, at most
  600 UTF-16 units total. Oversized sentences are rejected, not silently truncated.
- JSON validation, bounded output, non-thinking mode, deadline/cancellation,
  short-lived memory caching and cooldowns. No automatic retries.
- Structural and mechanical preservation checks for numbers, selected units,
  uppercase terms, modality anchors and literal quotations.
- Without networking, documented fixtures support range testing. API failures
  never silently fall back to these fixtures.
- TextEdit AX observation is active only during a requested operation/preview,
  to invalidate changed input or focus. It never schedules another model request.
- Acceptance/native undo arrive in T2; on-demand explanations and post-acceptance
  review arrive in T3. Old experimental settings do not enable these in T1.

Automated tests use synthetic in-memory responses. Users evaluate TextEdit UI,
real-model quality and their input-method experience. This build keeps the draft
unchanged while validating the new product flow.

TypeTide is an isolated MIT reference, not the product base. LingoMend owns its
Smart Scope and companion UX. Private validation notes are not published.

## Try it locally

Requires macOS 14+ and complete Xcode with its toolchain selected.

```sh
swift test
sh Scripts/build-local-app.sh
```

Quit any old LingoMend process from its LM menu, then open `.build/LingoMend.app`.
In **LM → 设置**, allow TextEdit; manually grant macOS Accessibility permission
to this app. Create a synthetic TextEdit document.

Type `This works 轻载条件下.` or `I very like 这个方案.`, then press
**Control-Option-L** to see context, advice and differences. **Control-Option-Period**
dismisses it. Ordinary typing and IME composition keys remain untouched.

To use real suggestions, open **LM → 设置**, keep the DeepSeek preset,
enter your key privately, and click **测试连接（合成文本）**. Then enable
**使用配置的模型服务** and save. The explicit test can make one paid request
even while normal networking is disabled. It does not read other apps.

See the [TextEdit T1 experience steps](docs/textedit-t1-experience.md) for setup
and a short user-driven test. Rebuilt ad-hoc signed apps can require manual
Accessibility reauthorization; no development certificate is included.

## Principles and architecture

- Users write first; advice completes their current expression and corrects
  necessary English grammar/collocations, preserving usable wording.
- Preserve the author's facts, opinions, uncertainty and tone; let users decide
  whether to accept and when to learn. Unfinished ideas remain with the author.
- Read-only context and edit permission are separate; scope is decided locally.
- Idle operation does not read drafts or call the model. The AX bridge may obtain
  the focused field locally to resolve a sentence; only bounded context is sent.
- Swift 6, AppKit and SwiftUI; no Electron, bundled large model or cloud relay.
- No key logging, clipboard-based capture, or full-draft logs/analytics.
- Existing local learning foundations are retained for T3; full drafts are not
  retained. Assisted acceptance and independent-use evidence remain distinct.
- Model credentials use the OS Keychain, isolated by complete normalized endpoint.
  Switching endpoint does not reuse another endpoint's key. No embedded key or relay.
- A successful JSON check is not proof of semantic correctness; users decide
  whether to accept. External service retention is governed by that provider.

## Delivery

See the [staged development plan](docs/development-stages.md). Each stage ends
with tests/build, Conventional Commits and a normal remote push, a report and
user test steps. Work stops for feedback before proceeding to the next stage.

Next: TextEdit feedback on sentence scope and natural advice; T2 safe acceptance
and native undo, then T3 learning. Other-app compatibility follows that core loop.

## License

MIT. Any reused third-party code must retain its notices and be recorded in
`THIRD_PARTY_NOTICES.md`.
