# Changelog

## 0.8.1 (build 12)

- Strip developer paths from release binaries before signing and audit app bundles.
- Audit commit metadata, non-example emails and local-only private-name lists.
- Package universal Apple Silicon and Intel binaries.
- Add synthetic native UI previews and a reproducible offline renderer.
- Record identity-free widget timeline counters for configuration diagnostics.


## 0.8.0 — 2026-11-18 (build 11)

- Add independent Edit Widget account selection with small/medium/large capacities of one/two/three.
- Add menu bar account selection and a configurable maximum; use one shared selection for bars and percentages.
- Start clean installations with no configured accounts and prepare English deployment, architecture and security documentation.
- Add public-tree auditing, clean Git export and versioned release packaging.
- Exclude local operational diagnostics from public source distributions.

## 0.7.1 — 2026-11-17 (build 10)

- Reuse container-local usage checks for at most 15 seconds, bound to fresh profile identity, credential fingerprint and runtime; discard after reset submission.
- Handle throttled Claude reset preflight with at most one 60-second GET retry; never retry a reset POST.
- Validate confirmation age and expiry after network waits and allow enough bridge time for the bounded preflight.
- Save sanitized reset-stage diagnostics, distinguish provider rejections, and record durable submission outcomes.

## 0.7.0 — 2026-11-16 (build 9)

- Compact overview cards, spacing, quota rows and timestamps without reducing native text size.
- Show exact reset and measurement dates on hover; keep model availability in Sources only.
- Summarize credits and extra usage in expandable rows, and group reset details with their confirmation buttons.
- Render provider-colored proportional quota bars directly in the app.

## 0.6.2 — 2026-11-16 (build 8)

- Dismiss the menu bar popover on outside left, right or middle clicks, including after opening it by clicking the status item.

## 0.6.1 — 2026-11-16 (build 7)

- Retry failed usage reads at the configured refresh interval instead of increasing the delay after each failure.
- Honor provider Retry-After for both automatic and manual refresh.
- Show Cached / retrying and the next automatic check on account cards; keep manual sources manual.

## 0.6.0 — 2026-11-16 (build 6)

- Collapse Limit resets by default in account cards; retain availability counts and reveal details/actions on expansion.
- Increase widget typography with prominent percentages and larger account names.
- Add native-resolution colored usage bars to the menu bar and explicit capsule bars to desktop widgets.
- Re-register the installed widget extension and terminate its old process after app updates so WidgetKit loads the new executable.
- Keep the polling timer in common run-loop modes; add widget timeline entries that mark old readings stale even if the host stops.
- Block stale reset confirmations in the host after a runtime or grant change, before invoking the bridge.
- Add isolated end-to-end upgrade and rollback simulations for both providers, with no real Docker or reset access.

## 0.5.0 — 2026-11-16 (build 5)

- Route usage, model catalogs and confirmed reset operations through version-bound provider adapters.
- Preserve exact runtime bindings when adding adapters; unknown runtimes use read-only fallbacks and explicitly unsupported runtimes stop before authentication.
- Show verified, unverified or unsupported compatibility in Sources, including runtime detection on failed usage reads.

## 0.4.0 — 2026-11-16 (build 4)

- Check model availability once per connection, then only manually in Sources; persist attempts across restarts.
- Mark model catalogs as last-known after runtime changes without triggering automatic checks; clear old-account catalogs.
- Explain Claude model access uncertainty and manual runtime compatibility maintenance.

## 0.3.0 — 2026-11-16 (build 3)

- Add separately confirmed direct Claude and GPTMock/Codex reset actions, fresh eligibility checks and durable duplicate-submission protection.
- Add daily per-source model catalogs with persistent schedules and explicit account versus container support.
- Display app, provider runtime, adapter and collector protocol versions.
- Disable direct resets for unvalidated runtime versions or a runtime change after confirmation; retain read-only inspection where the schema remains compatible.

## 0.2.0 — 2026-11-16 (build 2)

- Enable local sandboxed WidgetKit widgets without App Groups.
- Replace view scaling with native text sizing for sharp zoom.

## 0.1.0

- Initial menu bar app and dashboard with local container usage monitoring.
