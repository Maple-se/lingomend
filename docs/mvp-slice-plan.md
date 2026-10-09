# macOS MVP: companion-first slice

## Active slice: TextEdit sentence advice (2026-10-09)

The current plan is [TextEdit T1–T4](development-stages.md), based on
[scenario requirements](research/textedit-scenarios-and-requirements.md).
Write first; ask for help with the current sentence; preserve the author's voice
while making necessary English corrections. Learning is an on-demand branch.

- T1: explicit TextEdit-only help; sentence/selection context; bounded real-model
  advice and statuses; original-context and difference preview; no external writes.
- T2: safe acceptance, stale-source checks, caret/format preservation and native undo.
- T3: short explanations, post-acceptance review and voluntary local expression cards.
- T4: TextEdit feedback convergence, followed by wider compatibility and release work.

Experience steps: [TextEdit T1](textedit-t1-experience.md).
The following describes the earlier prototype and retained foundations.

## Historical prototype slice

Product direction updated on 2026-10-03: keep the user's existing input method.
A caret-adjacent, non-activating candidate is the main flow. The learning panel
opens only on demand; shortcut-to-modal replacement is not the product.

The current delivery boundaries are in [development stages](development-stages.md).
Each stage ends with tests/build, conventional local commits and a normal remote
push, a progress report, and user experience steps. Development stops there
until feedback or authorization to continue.

## Stage 1

- Local native-editor experience with deterministic suggestions; no permission
  needed and no network requests.
- Explicitly enabled, allowlisted Accessibility notification observation.
  No key logging, clipboard capture or continuous polling.
- Resolve the current paragraph and nearest Chinese placeholder. Inline
  acceptance cannot silently apply a broader sentence rewrite.
- Debounce, throttle and discard stale generations on focus/content/selection
  changes. Position candidates using caret bounds; unsupported positioning
  fails quietly, not into a large modal.
- Ordinary typing keys remain with the existing input method. Modified
  acceptance/learning/dismissal keys are active only for a candidate.
- Cross-app writes remain experimental, opt-in, and limited to TextEdit/Safari.
  Checks address the captured element/range, without synthetic paste.
  AX native undo and external IME composition are not yet verified.
- Previously started model adapter and learning-data foundations are preserved
  with synthetic tests; real-provider settings and aggregate statistics are
  disabled in the Stage 1 application.

User testing: [Stage 1 experience](stage-1-experience.md).
Detailed validation outcomes remain local and ignored.

## Next

Stage 2 enables real providers and resolves acceptance/composition/undo
compatibility using Stage 1 feedback. Stage 3 builds the learning library and
independent-use evidence UI. Stage 4 covers performance, wider compatibility,
stable signing and release readiness. Ten-app testing does not block Stage 1.
