# TypeTide validation plan

## Timing

Run a short, isolated spike alongside LingoMend MVP foundations. ADR-0002
narrows this plan: the goal is targeted reuse, not adoption of all TypeTide.

The dated evidence and application matrix are retained in ignored local
Stage 0 notes, not published in this repository. Do not make the
targeted-reuse decision until the representative-app and safety checks are
recorded. Unverified scenarios must remain open for LingoMend's own bridge.

## Isolation

- Use a separate local checkout or experimental repository.
- Pin and record the exact upstream commit.
- Do not merge upstream source into LingoMend during evaluation.
- Record behavior, measurements, patches, and license findings locally.

## Pre-MVP representative applications

1. TextEdit — native plain-text control
2. Safari — web text area
3. VS Code — editor-specific input stack

If an app is unavailable, record why and choose an available app with a
different text-input implementation. This is a sampling gate, not a
compatibility-rate claim.

## Post-MVP compatibility matrix

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

For every representative application, record the result and exact failure mode. A passing
unit test or a mocked editor test does not count as an application-level pass.
Any wrong-field write, lost user clipboard change, or broken undo disqualifies
reuse of that TypeTide path. It does not block building a safer LingoMend path;
the latter must pass equivalent tests before MVP release.

## Post-MVP performance targets

- Idle CPU: below 0.5% on the reference machine.
- Idle resident memory: below 60 MB, excluding local models.
- Installed size: below 30 MB, excluding local models.
- Trigger to visible panel: P95 below 150 ms before model latency.
- Scope resolution: P95 below 100 ms.

These remain product targets, not conditions for beginning MVP development.
The TypeTide experimental build already misses the size and memory targets;
LingoMend's own build must be measured separately.

## Maintainability checks

- Build and test instructions reproduce on a clean machine.
- Signing does not repeatedly invalidate Accessibility permission.
- Provider code can be separated from translation-specific prompts.
- CoachCore and LearningCore can integrate without duplicating them per platform.
- Upstream dependencies and their licenses are documented.
- There is no mandatory telemetry or hosted relay.

## Exit outcomes for each candidate technique

- Reuse a small, reviewed MIT module with its provenance and notices.
- Adapt an interaction or architecture idea without copying source.
- Implement a clean native LingoMend module when safety or product behavior
  requires a different design.

A full-product fork is not the default exit. Ten-app and distribution-budget
checks continue after the first MVP slice; they are not prerequisites for
starting it.
