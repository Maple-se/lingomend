# Contributing

LingoMend is a native macOS English-expression companion. Start with the user problem and the affected app/area. Keep changes small enough to verify; discuss large architectural changes first.

Read [AGENTS.md](AGENTS.md) for mandatory project development rules. In particular, **documentation consistency is part of implementation and release acceptance**, not optional follow-up work.

## Canonical project records

| Information | Maintain here |
| --- | --- |
| Effective product behavior and requirement backlog | [product requirements](docs/product-requirements.md) |
| Current stage definitions and next stage | [development stages](docs/development-stages.md) |
| Current build, app compatibility and unresolved/deferred tasks | [status](docs/status.md) |
| Version metadata | App/Info.plist |
| Current startup and user regression steps | [experience guide](docs/t3-global-experience.md) |
| Technical decisions and their supersession | docs/adr/ |

Change related code and documentation together. Search for old versions, retired UI, conflicting stage names and obsolete support claims before committing. Historical documents must say they are historical and link to current records. Do not keep multiple independent current plans or compatibility tables.

## Implementation and evidence

- Preserve the author's meaning and native editing/undo. Refuse stale or ambiguous edit targets.
- Never log drafts, prompts, responses, clipboard contents or credentials. Keep generated evaluation reports and real-app validation records local and Git-ignored.
- Keep platform integration separate from coaching and learning. Record copied/adapted third-party code in THIRD_PARTY_NOTICES.md.
- Use meaningful deterministic tests for changed behavior. Default tests are offline. Explicit live synthetic review is described in [quality review](docs/quality-review.md).
- Distinguish implementation, automatic checks and actual app acceptance. Record the area, evidence build and limits in the status page. User feedback can prove a flow; a test count cannot certify global compatibility.

## Delivery checks

```sh
swift test --disable-sandbox
sh Scripts/build-local-app.sh development
```

Review the diff, local links and version agreement. Confirm logs/credentials are not staged. Commit with Conventional Commits and push only within the user's authorization; never force-push shared history. Each stage ends with the build/commit, actual evidence, remaining tasks and user test steps, then stops for feedback.
