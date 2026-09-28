# TypeTide Stage 0 validation log

Status: **in progress; no base decision**  
Started: 2026-09-28  
Target: 5–7 focused development days before production Accessibility, shortcut,
floating-panel, or text-replacement work in LingoMend.

## Reproducible baseline

- Upstream: <https://github.com/everettjf/typetide>
- Experimental fork: <https://github.com/Maple-se/typetide>
- Fixed upstream commit: `e14dfd1b7178a9e7013e49268765be06cae171e9`
  (2026-09-24, “Sync website and guides with macOS download improvements”)
- Remote experiment branch: `stage0/validation-e14dfd1`; it points to that
  exact commit. `origin` is the fork and `upstream` is the original project.
- Local experiment checkout: `LingoMend/.stage0/typetide`, ignored by the
  LingoMend repository. TypeTide source has not been copied into LingoMend.
- Reference machine: Apple Silicon MacBook Air, macOS 27.0 (26A428), Xcode
  27.0 (27A266a), Swift 6.4, Metal Toolchain 27A266a.

## Day 1 — 2026-09-28

| Check | Result | Evidence / limitation |
| --- | --- | --- |
| LingoMend toolchain | Pass | Active developer directory is `/Applications/Xcode.app/Contents/Developer`. LingoMend `swift test`: 9 passed. |
| TypeTide package resolution | Pass | Xcode resolved 10 Swift package dependencies. |
| TypeTide Debug build | Pass | `xcodebuild -quiet -project TypeTide.xcodeproj -scheme TypeTide -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath ../.stage0-derived-data CODE_SIGNING_ALLOWED=NO build` from `macos/`. Metal Toolchain had to be installed separately. |
| TypeTide unit tests | Pass with skips | 33 passed, 3 skipped (live Ollama, live range download, live built-in model). No failures. |
| Mock editor end-to-end test | Pass | 1 passed. It substitutes the replacement function with a test override; it does not prove real Accessibility, clipboard, or native undo behavior. |
| App size | Fails current budget | The unsigned Release `.app` is 61,396 KiB (about 60 MiB), versus the planned <30 MB installed-size budget; the Debug `.app` is 100,240 KiB. The Release executable is about 54 MiB and resources about 6.3 MiB. No model is bundled. |
| Development signing | Open | `security find-identity -v -p codesigning` found 0 valid local signing identities. A stable multi-day Accessibility grant may need a development identity or a controlled ad-hoc test strategy. |

### Initial source audit

- Explicit selection: `macos/TypeTide/Core/SelectionCapture.swift` reads AX
  selected text, then falls back to synthetic Command-C. This is a promising
  base, but per-app capture success has not been measured.
- Smart Scope: a caret without a selection currently reads the entire AX field
  for rewrite. Paragraph-at-caret resolution is not implemented in TypeTide.
- Safe replacement: `TriggerController.swift` checks the current request ID
  after model work, but `TextReplacer.swift` does not recheck the original
  focused element, selected range, or source text before Command-A/Command-V.
  The read popup's Replace callback has the same issue. This can write to a
  different field if focus changes during generation.
- Clipboard: `PasteboardHelper` snapshots and restores multiple items and
  representations; its two unit tests pass. Both capture and replacement use
  fixed delays before an unconditional restore. A user clipboard change during
  that interval would be overwritten; this requires a race test and a patch.
- Undo: synthetic paste can participate in native undo, but the existing tests
  do not verify Command-Z in any target application. `Keyboard.press` returns
  success when it posts events, not when the target consumes them.
- Excluded apps: `AppSettings.shouldSkipFrontmostApplication()` is checked
  before capture. It is not rechecked immediately before replacement.
- Privacy: operational diagnostics have no source text, translation, app name,
  URL, or credentials in their schema. No mandatory hosted translation relay
  was found. The app does make an automatic daily request to GitHub Releases
  for updates; an OpenAI-compatible endpoint is optional.

These are code findings, not measured failure rates. In particular, the
current implementation does **not** pass LingoMend's safe-replacement gate.

The upstream repository was last pushed on 2026-09-24. On day 1 it had one
open issue (Vietnamese language support). The Windows tree contains a C++20
Win32/CMake implementation, an offline self-test and integration scripts, and
a manual release-candidate checklist. It has not been built or exercised on a
Windows machine in this spike. Its replacement path also restores a clipboard
snapshot after a delay and does not revalidate the original focused control.

### License inventory

The TypeTide repository is MIT licensed and retains the 2026 everettjf notice.
Resolved Swift packages at the fixed commit:

| License | Packages |
| --- | --- |
| MIT | `mlx-swift`, `mlx-swift-lm`, `yyjson` |
| Apache 2.0 | `ollama-swift`, `swift-asn1`, `swift-collections`, `swift-crypto`, `swift-jinja`, `swift-numerics`, `swift-transformers` |

This is a source/dependency inventory, not yet a distributable-bundle notice
audit. The optional built-in model has separate Gemma terms; no model was
downloaded for this baseline.

## Target application matrix

User scope update: do not install Chrome, Notion, or Slack on this Mac.
Their native-client rows remain untested and deferred; other applications
must not be counted as substitutes. The user approved manually granting
Accessibility access to the TypeTide experimental build.

The fixed Release build is staged at `LingoMend/.stage0/apps/TypeTide.app`.
It has a local ad-hoc bundle signature (`com.xnu.typetide`), and
`codesign --verify --strict` passes. The source baseline is unchanged.
Accessibility authorization is pending manual completion; do not infer the
grant from the user's approval alone. Keep this copy at its fixed path during
testing. A rebuilt or replaced copy may require authorization again.

Permission handoff observation: macOS 27 calls this settings pane “Device
Control and Data Access” (设备控制和数据访问). Its TypeTide switch is on, but the
running staged app still displays “Grant Permission”. The running executable
path was verified as `.stage0/apps/TypeTide.app/Contents/MacOS/TypeTide`.
The existing entry may refer to a previous build; the user must authorize the
current copy before live cross-application tests can proceed.

`Pending` means **no compatibility claim**. Use synthetic, non-sensitive text
only. Run each scenario with a stable original clipboard item and repeat with
the clipboard changed during model latency.

| Application | Local availability on day 1 | Selection / caret scope | Safe replace / undo | Clipboard / focus race | Latency |
| --- | --- | --- | --- | --- | --- |
| TextEdit | Installed | Pending | Pending | Pending | Pending |
| Safari | Installed | Pending | Pending | Pending | Pending |
| Google Chrome | Deferred: user declined installation | Untested | Untested | Untested | Untested |
| Microsoft Word | Installed | Pending | Pending | Pending | Pending |
| Apple Mail | Installed | Pending | Pending | Pending | Pending |
| Notion | Deferred: user declined installation | Untested | Untested | Untested | Untested |
| Obsidian | Installed | Pending | Pending | Pending | Pending |
| Slack | Deferred: user declined installation | Untested | Untested | Untested | Untested |
| VS Code | Installed | Pending | Pending | Pending | Pending |
| ChatGPT web input | Safari installed; web session not checked | Pending | Pending | Pending | Pending |

### Repeatable scenarios per application

1. Explicitly select `under light-load conditions` and verify exact capture.
2. Put the caret inside a long, mixed Chinese/English paragraph; verify only
   that paragraph is offered by Smart Scope. Use a short field separately.
3. Replace a selected phrase, then Command-Z and Command-Shift-Z; compare the
   full document and selection to their expected states.
4. Start generation, change focus to a second field, then complete generation.
   The first and second fields must remain unchanged; copy-only is acceptable.
5. Start generation, edit the source text, then complete generation. No stale
   replacement may occur.
6. During fallback capture and during replacement, change the clipboard from a
   multi-format sentinel to a new user item. Preserve the user's latest item.
7. Put the app on the excluded-app list and verify no capture or replacement.
8. Measure trigger-to-panel and scope-resolution latency over at least 30
   repetitions per supported app; report P95 and failure count.

## Remaining focused days

- Day 2: establish a stable signed or ad-hoc experimental app and Accessibility
  grant; test TextEdit, Safari, and Mail.
- Day 3: test Word, Obsidian, and VS Code; record rich-text and editor-specific
  selection behavior.
- Day 4: test ChatGPT web input and repeat failures in available applications.
  Chrome, Notion, and Slack native-client tests are deferred per user request.
- Day 5: patch any focus, source-revision, clipboard, and undo failures in the
  **experimental fork**, then repeat the affected app cases.
- Day 6: measure idle CPU/RSS, Release app size, trigger latency, scope latency,
  permission persistence, and startup behavior. Release size already exceeds
  the budget; determine whether removing the integrated MLX backend or other
  packaging changes can bring it below 30 MB without harming the desired UX.
- Day 7 if needed: review macOS/Windows implementation parity, dependency
  notices, provider boundaries, maintenance cost, and choose formal fork,
  attributed MIT modules, or a clean native bridge.

## Decision gate

The formal fork is eligible only after all ten app rows have measured results,
all wrong-field/clipboard-loss/undo defects have been fixed and retested, and
the performance and distribution checks in the validation plan are complete.
If only isolated system modules pass, evaluate migration with retained MIT
notices. If the safety changes require replacing most of capture/replacement,
prefer LingoMend's own native bridge. No outcome has been selected yet.

The three deferred native-client rows prevent a claim of ten-application
coverage. Report any interim recommendation with this explicit limitation;
do not silently treat the original coverage gate as passed.
