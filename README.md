# LingoMend

**English** | [简体中文](README.zh-CN.md)

> **The goal is to need us less.**

Write what you can. Learn what you can't.

LingoMend is a lightweight macOS English-expression companion. Keep your input method,
write what you can, and use Chinese for expression gaps. Ask for help with the current
sentence or a selection; necessary English corrections preserve your facts, opinions and
voice. Read selected expressions in context on demand.

## Features

This is a development app. Editor compatibility varies, and WeChat capture is not yet supported.
The current version is specified in [App/Info.plist](App/Info.plist).

- **Control-Option-L**: help with the complete current sentence, or explicitly selected
  words/sentences/short passages. Fill genuine Chinese gaps and fix necessary English
  errors; good writing can return unchanged, ambiguity can return clarification.
- **Control-Option-D**: explain selected English words or sentences using actual captured
  context. Missing/partial context is labelled. Reading never edits the source.
- A non-activating card near the captured caret or text shows request progress, then expands
  in place to show the original text, suggestion and differences. It keeps the same attachment
  edge and respects the system Reduce Motion setting. Successful acceptance stays nearby
  briefly; errors use the menu-bar notice. Some editors expose only control bounds, so
  positioning can be near the input area rather than the exact caret.
  **Control-Option-Return** or the Accept button applies a suggestion; **Escape** or
  **Control-Option-Period** dismisses it. Ordinary Return/Tab stay with the editor.
- Source, focus and selection are rechecked before one native paste. Verify the result and
  caret, conditionally restore the clipboard, and use the original editor's native undo.
- Basic attributed runs are used when available. TextEdit/Word/Notes ordinary text can use
  a guarded text-only fallback for private attributes, with a visible format limitation;
  recognized structural content refuses that fallback. Complex formats remain app-specific.
- Direct DeepSeek-compatible Chat Completions, configurable endpoint/model, Keychain
  credentials, explicit networking, bounded requests, cancellation, cooldown and memory cache.
  No automatic paid retries or silent fallback to demo results on provider failure.
- Local, optional content-free diagnostics: development defaults on; release/unknown defaults
  off. At most five 1 MiB log files per channel with seven-day retention. No log upload.

For an explanation, use the candidate's
explicit **为什么这样改？** action, then open **最近一次建议…** from the menu after a
successful acceptance. The explanation is optional and does not gate acceptance; the recent
record is in-memory for the current session and does not save the full draft.

## Try it locally

Requires macOS 14+ and complete Xcode with its toolchain selected.

```sh
swift test --disable-sandbox
sh Scripts/build-local-app.sh development
```

Quit the old process from the menu bar and open `.build/LingoMend.app`. In
**Settings → Access and Apps**, allow TextEdit or enable other-app on-demand access, and
manually grant Accessibility permission. Rebuilt ad-hoc signed apps may need reauthorization.
Configure the model under **Model Service**; a connection test sends one synthetic request
and may incur a charge even with normal networking disabled. Never put a key in this repo.

To request help, place the caret in a sentence or select text and press **Control-Option-L**.
Review the suggestion, then accept it with **Control-Option-Return** or dismiss it with
**Escape**. To explain selected English text in context, press **Control-Option-D**.
Use the original editor's undo command to reverse an accepted change.

## Product and privacy contract

Users write first and request help. Idle operation does not read drafts or call a model.
The AX bridge may obtain a focused field locally to resolve a sentence; only bounded
text is sent: current sentence ≤600 UTF-16, explicit passage ≤1200, reading selection
≤1200 and total reading context ≤2000. Local capture is not the same as network scope.

No key logging, hidden Copy capture, clipboard monitoring, OCR or automatic continuation
of unfinished ideas. Clipboard contents are borrowed only during acceptance and are not
sent to the provider or logs. External event delivery and clipboard restoration are not
atomic; unclear post-dispatch results are reported without automatic retry or undo.
Model format checks do not prove semantic correctness. See [security boundaries](SECURITY.md).

## Architecture and contributions

Swift 6.1, SwiftPM, AppKit and SwiftUI; no Electron, bundled large model or cloud relay.
CoachCore handles model contracts; MVPFlow handles proposals; PlatformBridge handles AX,
scopes and native editing; DiagnosticsCore records bounded events; LearningCore retains
future expression-store foundations. TypeTide is an isolated MIT reference, not the base.

Read [AGENTS.md](AGENTS.md) and [CONTRIBUTING.md](CONTRIBUTING.md). Internal planning,
runtime logs, evaluation results and validation records remain local and Git-ignored.

## License

MIT. Reused third-party code must retain its notices and be recorded in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
