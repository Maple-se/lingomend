# LingoMend

> **The goal is to need us less.**

Write what you can. Learn what you can't.

LingoMend is a lightweight macOS English expression companion for non-native
speakers. Keep your existing input method, write what you can, and use Chinese
for expression gaps. Ask for help with your current sentence; necessary English
corrections preserve your meaning, opinions and voice. Learning opens on demand.

## Status: TextEdit T2 + local diagnostics build (0.4.1)

The current build delivers sentence advice and explicit native acceptance in TextEdit:

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
- Explicit **Control-Option-Return** or candidate-button acceptance; **Escape** or
  **Control-Option-Period** cancellation. Ordinary Return/Tab are not intercepted.
- Locally bounded edits, final source/focus/selection checks, one process-targeted
  native paste, result verification and conditional caret placement.
- Clipboard borrowing only during acceptance: in-memory multi-item/type snapshot,
  ownership-checked restoration, refusal for unmaterializable/oversized data.
  Third-party clipboard history/sync may retain temporary contents.
- AX attributed-text conversion and local run preservation for basic fonts,
  bold/italic, colors and underline. Unsupported format refuses, without a plain-text fallback.
- Single native editor undo tested in an isolated NSTextView. Actual TextEdit
  cross-process paste, undo and formatting remain user-acceptance checks.
- On-demand explanations and post-acceptance review arrive in T3.
- Optional local diagnostics with a closed, content-free event schema and random operation IDs.
  Development distributions default on; release/unknown distributions default off,
  with independently persisted preferences. Settings changes take effect immediately.
  At most five 1 MiB JSON Lines log files per channel, seven-day retention and a
  256-event queue. No telemetry, text/clipboard/prompt/credential logging or log uploads.

Diagnostics settings and experience checks: [T2.1 local diagnostics](docs/diagnostics-experience.md).

Automated tests use synthetic in-memory responses. Users evaluate TextEdit UI,
real-model quality and their input-method experience. The draft stays unchanged
until explicit acceptance; unclear paste outcomes are reported without retries.

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
dismisses it, as does Escape. **Control-Option-Return** accepts a suggested edit;
release modifier keys after pressing it. Use TextEdit's **Command-Z** to undo.
Ordinary typing and IME composition keys remain untouched.

To use real suggestions, open **LM → 设置**, keep the DeepSeek preset,
enter your key privately, and click **测试连接（合成文本）**. Then enable
**使用配置的模型服务** and save. The explicit test can make one paid request
even while normal networking is disabled. It does not read other apps.

See the [TextEdit T2 experience steps](docs/textedit-t2-experience.md) for setup
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
- Temporary acceptance clipboard contents are not sent to the model or stored.
  Clipboard restore and event dispatch are not atomic across processes; crashes,
  late events and concurrent copy/focus changes remain explicit limitations.
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

Next: user acceptance of TextEdit T2 editing, undo and formats, then T3 learning.
Other-app compatibility follows that core loop.

## License

MIT. Any reused third-party code must retain its notices and be recorded in
`THIRD_PARTY_NOTICES.md`.
