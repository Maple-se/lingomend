# Security and privacy boundaries

LingoMend is a development app. See the [README](README.md) for setup and current user-facing functionality.

## Capture and networking

- Writing and reading begin only after an explicit shortcut. Idle operation does not capture drafts, record keystrokes or schedule model requests. AX notifications are observed only during an active request/preview to invalidate stale results.
- Access to other apps is opt-in. With global access disabled, only explicitly allowed apps can respond; current settings expose TextEdit permission and a global access switch. This is not a per-document or per-site boundary, and a per-app exclusion UI has not shipped.
- Native secure-field subroles are refused. An inaccessible custom field is not made readable through hidden Copy, OCR or clipboard monitoring.
- The AX bridge may read the whole focused control locally before resolving a sentence. Writing sends only its bounded target/left/right, intent and extent; no window title, document path, app identity or learning history. Current sentence: at most 600 UTF-16 units; explicit passage: 1200. Reading sends selected text and actual bounded context: selection at most 1200, total at most 2000.
- Networking defaults off. The model-service switch authorizes explicit requests in permitted apps. A connection test separately sends one synthetic sample even while that switch is off. Client cancellation does not guarantee server cancellation or zero charges.
- Credentials use Keychain, isolated by normalized complete endpoint. Redirects are refused; cookies and disk response caching are disabled. HTTP is allowed only for loopback development services. A provider controls retention after transmission.
- Response checks constrain structure, size and some meaning anchors; they do not establish semantic equivalence. Draft text and model output never become executable instructions or edit coordinates.

## Editing and clipboard

- Only explicit acceptance permits editing. Recheck the same source app, control, text, revision and selection; send one process-targeted native Cmd-V. Never generate Return/send, activate another editor or overwrite a whole field as a fallback.
- Borrow the clipboard only during acceptance. Materialize old data in memory; refuse data that cannot be saved reliably. Restore only while ownership/version still belongs to this operation; preserve newer user copies. Clipboard contents are not sent to the provider or logs.
- Use basic attributed runs when available. Ordinary native text may use a text-only fallback with an explicit format limitation. Known links, attachments, lists/tables or advanced structural styles must not be stripped by that fallback. Actual editor formatting and undo remain app-specific checks.
- Verify the paste and caret. If dispatch occurred but the result is unclear, report uncertainty without automatic retry or undo. Event delivery, external edits and clipboard restoration cannot be made atomic across processes; forced termination, late events or concurrent changes remain limitations.
- AX has no universal IME-composition API. Commit composition before requesting/accepting. Rebuilt ad-hoc signed apps can need manual Accessibility reauthorization.

## Local data and diagnostics

- Runtime diagnostics contain fixed events, app system name/bundle identifier and bounded structural metrics; never text, prompts, responses, keys, URLs, document titles or clipboard data. Logs remain local, capped and Git-ignored. Development defaults on; release/unknown channels default off.
- Synthetic model review is explicitly opt-in; generated cases/results and private acceptance notes remain in the ignored local Diagnostics directory. Default tests use synthetic in-memory responses and do not call a paid service.
- Learning-store modules exist, but voluntary cards and independent-use evidence are not connected to the current app. No full drafts are persistently cached by writing/reading services; bounded short-lived request caches stay in memory.

## Reporting

Do not publish private drafts, credentials or raw logs in issues. Report the app/area, build, operation and short visible error. For sensitive vulnerabilities, open a minimal issue requesting a private reporting channel until a dedicated contact exists.
