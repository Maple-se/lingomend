# ADR-0001: Validate the system layer before choosing the product base

- Status: Accepted
- Date: 2026-09-20

## Context

LingoMend needs reliable system-wide text capture, Smart Scope resolution, safe replacement, a global trigger, and a lightweight floating result panel. TypeTide already implements a closely related MIT-licensed system layer on macOS and Windows, but its real compatibility and long-term fit have not yet been verified.

Starting a complete native system layer now could duplicate work. Committing the product to a fork before testing could create a different form of rework.

## Decision

Run a disposable TypeTide spike before implementing LingoMend's production Accessibility bridge.

The LingoMend repository may develop only base-independent modules during the spike:

- CoachCore
- LearningCore
- platform protocols and deterministic Smart Scope logic
- product documentation and test fixtures

Do not copy TypeTide source into this repository during the spike.

## Decision gate

Use TypeTide as the formal base only if it passes the compatibility, safety, privacy, performance, and maintainability checks in `docs/research/typetide-validation-plan.md`.

If most of the system layer remains useful, create a transparent GitHub fork and keep MIT. If only isolated files are useful, retain their notices in a new repository. If the structure blocks Smart Scope or safe learning integration, implement the bridge cleanly in Swift.

