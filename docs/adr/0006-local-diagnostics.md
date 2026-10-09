# ADR 0006: Bounded, local-only development diagnostics

Status: implemented for T2.1; settings and actual TextEdit workflow await user experience.

## Decision

Use a standalone Foundation-based `DiagnosticsCore` with no logging dependency or
network transport. `DiagnosticRecording` takes only a closed `DiagnosticEvent`
schema plus an optional random UUID operation ID. A no-op recorder remains the
default for reusable services and native editing tests.

`LingoMendBuildChannel` is explicit distribution metadata, unrelated to Swift
optimization or `DEBUG`. Canonical Info.plist is release-safe; local packaging
sets development on the generated bundle before signing. Missing/invalid metadata
is unknown/off. Development, release and unknown overrides use separate
UserDefaults keys, independent of existing Codable API preferences.

## Events and privacy

Each help operation uses a random UUID across scope, model, preview and acceptance.
Session IDs reset on launch/re-enable/clear. UTC timestamps and per-session sequence
numbers locate events; monotonic elapsed milliseconds measure duration. Numeric
app versions/builds and channel metadata appear on session/file headers only.

Events cover lifecycle, permission checks, shortcut registration, scope/refusal,
service handling, actual provider invocation, caching/throttling/cooldown,
candidate presentation/dismissal and native editing phases. `modelStarted` starts
service handling, not necessarily a paid request: cache hits have no
`providerInvoked`. Even invocation is not proof that a server received/charged it.
Connection tests use separate random operation IDs.

The UI owns capture/scope/candidate events; SentenceService owns provider failures;
NativeTextEditPaste owns transaction and cleanup results. Normal cancellation is
info. `acceptanceFailed.dispatched` separates refusal before dispatch from
dispatched-but-unconfirmed outcomes. Clipboard restoration and caret results are
separate events; unconfirmed paste is never automatically retried.

No source, Chinese gap, replacement, explanation, prompt, clipboard bytes/RTF,
credentials, endpoint/model strings, request/response body, document identity,
path, account, revision/text hash or arbitrary error description is accepted.
Known HTTP status codes and fixed error enums are allowed. `invalidResponse`
remains one category until the provider genuinely distinguishes parsing/validation.
Event metadata can still reveal usage timing, lengths and failures: these logs are
diagnostic data, not anonymized data or a learning history.

## Storage and failure boundaries

Each channel has a private directory under `~/Library/Logs/LingoMend/` with 0700
permissions; five owned `.log` files have 0600 permissions, at most 1 MiB each.
Records are JSON Lines. The current file rotates to four older numbered files;
seven-day retention is evaluated on enable and rotation, not by an idle timer.
Oversized existing owned files are pruned. Incomplete trailing lines after a
force-quit are removed before append. A private, empty `owner.lock` prevents
simultaneous writers from rotating/clearing each other's files. Symlinks and
hard-linked files are refused. Cleanup only touches the five fixed log filenames,
never foreign files or recursively removes a directory.

A synchronous locked ingress caps pending events at 256, prioritizes retaining
errors/warnings over info/debug and aggregates drop counts. A utility serial
queue does short delayed batches (200 ms), with no idle polling or second
unbounded detached batch. Disk IO is never under the ingress lock or on the
main actor. No console/OSLog duplicate, automatic export, log viewer or upload.

Off immediately gates new events/discards queued events; acknowledgement waits for
the serial writer barrier, so earlier writes cannot appear afterwards. Old files
remain until explicitly cleared. Clear discards the old queue before serialized
deletion, preserves the requested switch, and starts a fresh header when enabled.
IO failure disables writing and exposes unavailable state without throwing into
model handling, native paste, clipboard cleanup or settings save. Status refreshes
on settings open/actions and ordinary workflow feedback, without idle polling.

On normal quit, clipboard verification/cleanup finishes first. Diagnostics then
gets up to 300 ms to drain/close, with a once-only timeout completion. No crash
capture or durable final-record guarantee is claimed. Force-quit/power loss may
lose pending data. An off release build creates no log directory/files.

## Verification

Tests use synthetic data, random temporary directories, mock failures and an
isolated named clipboard/hidden NSTextView, never actual user documents, keys,
general clipboard or paid API calls. Test defaults/override isolation, privacy,
correlation/deduplication, queue priority/cap, rotation/retention/permissions,
off acknowledgement, clear, concurrent ingress, write failure and bounded quit.
Actual settings interaction and TextEdit chain are user acceptance checks.

API checks used Context7's Apple Foundation reference for throwing FileHandle
[write/close methods](https://developer.apple.com/documentation/foundation/filehandle)
and [UserDefaults storage](https://developer.apple.com/documentation/foundation/accessing-settings-from-your-code).
