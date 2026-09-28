# TypeTide validation plan

## Timing

Run this spike immediately after the initial LingoMend repository is published and before production work begins on Accessibility capture, global shortcuts, replacement, or the floating panel.

Target duration: 5–7 focused development days.

The dated evidence and application matrix are in
[`typetide-validation-log.md`](typetide-validation-log.md). Do not make the
fork-versus-reimplementation decision until the matrix and safety gates are
complete.

## Isolation

- Use a separate local checkout or experimental repository.
- Pin and record the exact upstream commit.
- Do not merge upstream source into LingoMend during evaluation.
- Record behavior, measurements, patches, and license findings here.

## Target applications

1. TextEdit
2. Safari
3. Chrome
4. Microsoft Word
5. Apple Mail or Outlook
6. Notion
7. Obsidian
8. Slack
9. VS Code
10. ChatGPT web input

## Required scenarios

- Read an explicit selection.
- Resolve the paragraph around a zero-length caret.
- Handle English and Chinese in the same draft.
- Preserve the original clipboard on every path.
- Preserve native undo after replacement.
- Cancel safely when focus changes.
- Cancel safely when source text changes during generation.
- Fall back to copy-only when replacement cannot be proven safe.
- Respect an excluded-app list.
- Avoid writing source text, model output, and credentials to logs.

For every application, record the result and the exact failure mode. A passing
unit test or a mocked editor test does not count as an application-level pass.
Any wrong-field write, lost user clipboard change, or broken undo is a gate
failure until fixed and retested.

## Performance budget

- Idle CPU: below 0.5% on the reference machine.
- Idle resident memory: below 60 MB, excluding local models.
- Installed size: below 30 MB, excluding local models.
- Trigger to visible panel: P95 below 150 ms before model latency.
- Scope resolution: P95 below 100 ms.

## Maintainability checks

- Build and test instructions reproduce on a clean machine.
- Signing does not repeatedly invalidate Accessibility permission.
- Provider code can be separated from translation-specific prompts.
- CoachCore and LearningCore can integrate without duplicating them per platform.
- Upstream dependencies and their licenses are documented.
- There is no mandatory telemetry or hosted relay.

## Exit outcomes

### Formal fork

Choose this when the majority of the system layer survives and upstream fixes remain useful.

### New repository with attributed MIT modules

Choose this when only a few isolated modules survive. Preserve per-file notices and record the exact commit in `THIRD_PARTY_NOTICES.md`.

### Clean native implementation

Choose this when Smart Scope, replacement safety, or module boundaries require substantial rewrites.
