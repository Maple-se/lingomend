# macOS MVP: first useful slice

Status: in progress, 2026-09-29. The menu-bar preview, shortcut registration,
AX-only reader, deterministic local responder, copy action, and opt-in local
expression journal now compile; the demo preview has been observed running.
Cross-app capture and replacement have not yet passed LingoMend app-level
tests. This is a LingoMend implementation plan, not a plan to turn TypeTide
into the product.

## 1. Capture and Smart Scope

- Build a small, signed menu-bar app with a user-triggered shortcut and a
  non-activating review panel. Request Accessibility permission only when the
  user enables cross-app capture.
- Read focused text and UTF-16 selection directly through macOS Accessibility.
  The first reader is AX-only and read-only. Unsupported controls, oversized
  fields, missing permission, or inconsistent ranges fail explicitly; it does
  not synthesize Copy or mutate the clipboard.
- Resolve explicit selections first. With a caret only, use the current
  paragraph in a multi-line editor, or a genuinely short single-line field.
  Show the exact captured span before any model request.
- Validate capture in TextEdit and Safari. VS Code's observed clipboard
  fallback is a later, separately guarded compatibility path, not a reason
  to import TypeTide's clipboard helper.

## 2. Review and conservative replacement

- Use a deterministic local responder for end-to-end development before
  connecting any model provider. The review panel shows source, suggested
  minimum change, and explanation, with Copy always available.
- On Replace, re-read the target immediately. Require the same application,
  focused element, full source text, selection, and resolved range. Refuse
  stale output; never paste into a newly focused field.
- Support writing only through a target-app mechanism whose scope and native
  undo have been verified. Otherwise offer Copy; never perform an unguarded
  Command-A/Command-V sequence. Preserve a clipboard item the user changed
  while generation was running.
- Prove focus-change and source-edit refusals with two synthetic fields, then
  verify Replace and native Undo in TextEdit and Safari. These are release
  checks for LingoMend's implementation, not claims from TypeTide's sample.

## 3. Learning and lightweight operation

- After the main loop is reliable, record accepted suggestions locally and
  detect later independent reuse without reading all typing in the
  background. Keep the learning signal separate from assisted use.
- Measure startup, idle CPU/memory, and trigger-to-preview latency on the
  packaged build. Keep models and provider credentials outside the app
  bundle. No always-on hosted relay is required.

## Outside this slice

Ten-app coverage, a clipboard-based capture fallback, Windows implementation,
and auto-update packaging are later work. Their absence must remain visible
in the UI or release notes; no unsupported app should silently receive an
unsafe replacement attempt.
