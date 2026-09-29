# ADR-0002: Targeted TypeTide reuse, then LingoMend MVP

- Status: Accepted
- Date: 2026-09-29
- Supersedes: ADR-0001's full-base decision gate and production-work freeze

## Context

The product goal is a small LingoMend MVP, not a TypeTide derivative. A
full ten-application certification and a decision on adopting the entire
TypeTide repository would delay LingoMend-specific work. Initial TextEdit
testing confirmed that TypeTide's normal selected-text flow can work, but
caret-only rewrite captured the entire field. Source review also found no
focus/source revalidation immediately before replacement.

## Decision

- Keep the existing TypeTide fork as an **isolated experiment**, not the
  LingoMend product base. Preserve its pinned upstream commit and MIT notice.
- Inspect or prototype only the system integration techniques that could
  accelerate the MVP: Accessibility selection capture, shortcut registration,
  popup positioning, and app-specific replacement/undo behavior.
- Implement Smart Scope, replacement safety, the coaching flow, and learning
  behavior in LingoMend's own modules. Do not inherit TypeTide's whole-field
  caret behavior or its unguarded replacement path.
- Reuse a TypeTide source file only after a narrow code/license review and
  recording its provenance and notice. A formal GitHub fork of the entire
  product is **not required** for targeted MIT reuse.
- Complete the short Stage 0 gate below, then build and test the macOS MVP.
  Ten-application coverage is a later compatibility phase, not an MVP blocker.

## Short Stage 0 gate

Use synthetic text in three representative environments: TextEdit (native
plain text), Safari (web input), and VS Code (editor). If one is unavailable,
record the reason and use another available app with a different input stack.
For each, check trigger, exact selected-text capture, replacement, and native
undo where the experiment supports them. Separately probe focus changes,
source edits during generation, and clipboard changes; any wrong-field write
or clipboard loss is a disqualifier for **reusing that replacement path**.
An implementation that lacks the necessary pre-write checks, or restores a
stale clipboard unconditionally, can be disqualified by source audit without
deliberately triggering a hazardous write or clipboard loss on this Mac.

The gate may conclude that only capture or shortcut techniques are reusable.
It does not require patching TypeTide into a complete LingoMend product.
Unverified scenarios stay explicit in the private local log and must be tested against
LingoMend's own bridge before MVP release.

## Gate outcome — 2026-09-29

The three representative normal paths worked once each. VS Code required
TypeTide's clipboard capture fallback; TextEdit's caret-only path captured a
whole multi-line field. Source audit disqualified direct reuse of TypeTide's
replacement and clipboard helpers. No TypeTide source was copied. The
LingoMend MVP may start, while its own focus/source/clipboard/undo tests
remain a release gate. Detailed observations remain local.

## MVP first slice

1. User-triggered capture with explicit selection and caret-based paragraph
   or genuinely short single-line scope.
2. Show source, minimum-change suggestion, and explanation before any write.
3. Re-read the focused element and source immediately before replacement;
   refuse and offer copy-only on mismatch or unsupported app behavior.
4. Keep user clipboard changes intact and verify native undo in supported apps.
5. Add expression memory after the core capture/review/replace loop works.
