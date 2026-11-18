# User guide

## Sources and accounts

A source identifies a running Docker container and its provider. Add, edit, pause or remove sources in Sources. This never creates, stops or restarts a container. Two sources with the same verified provider account identity share a quota card; adding a container does not grant another account allowance. If identity cannot be verified, sources are not merged.

The app detects the runtime inside each container on every successful probe and can report detected metadata even when the usage request fails. Verified, unverified and unsupported compatibility are shown separately from connection health.

## Overview

Each card shows provider-reported utilization, remaining percentage and reset countdowns. Hover over reset and measurement timestamps for the full date. Scoped model windows remain separate. Credits, extra usage and offers expand to reveal details; a zero spending cap is not converted into a fabricated percentage. Model availability is shown only in Sources.

## Configure a desktop widget

1. Connect and refresh your sources in the app.
2. Add a small, medium or large Mock Usage widget from the macOS widget gallery.
3. Right-click it, choose Edit Widget, and choose the primary account.
4. Medium widgets also offer a second account; large widgets offer a third.

The capacities are fixed at 1, 2 and 3 to keep the content readable. Optional slots may be left empty. Duplicate choices appear only once. Leaving every slot empty uses automatic selection from available accounts, preserving the behavior of older unconfigured widgets. Selecting one account shows only that account. A missing explicitly selected account is not silently replaced by another account; refresh the app and edit the widget. Resizing hides slots that do not fit the smaller size.

The largest widget switches to a denser row layout when displaying three accounts. Each widget chooses independently. Selection uses a provider-scoped account fingerprint, not a raw provider account identifier. macOS stores widget configuration; it does not go into the repository.

The desktop may automatically dim widget colors according to macOS Desktop & Dock settings. The app does not override that system preference.

## Configure the menu bar

In Settings → Menu bar accounts, set Maximum accounts from 1 to 4. Enable Choose specific accounts to select them; turn it off to use automatic account order. Custom selection order follows the order in which accounts are enabled. At least one available account must remain selected. Lowering the maximum keeps the first selections that fit. Removed accounts can be replaced with Choose available accounts.

A common selection drives both bars and percentages, so their counts match. Mint represents GPTMock, orange Claude, and gray last-known data. Narrow screens cap the list further. macOS can still hide status items when other menu bar apps consume space. Hover previews usage; clicking keeps the panel open until another click outside it. Hover preview can be disabled.

## Refresh and recovery

Each source can use the app default, 1/5/15/30 minutes, or manual refresh. The default is five minutes on a new installation. Paused sources are not polled. The app's timer continues with the dashboard closed; quitting the app stops collection. Wake refresh is optional.

Failed reads retry at the configured interval (minimum one minute). Provider Retry-After can postpone both automatic and manual reads. Cached / retrying and the next check time distinguish temporary failures from fresh data. Renew expired credentials inside the provider container; the app never asks you to paste tokens.

Model availability is attempted once per connection and only manually thereafter through Check models now. Attempts persist across restarts. Upgrades mark old catalogs as last-known; account changes clear old-account catalogs. API-listed Claude models without verified account access are Unverified, not necessarily unavailable. Checks do not run model inference.

## Saved limit resets

Expand Limit resets to review each grant's scope, expiry, remaining count and current usability. Full and scoped resets have separate buttons. Nothing to reset is shown when all affected usage is zero. Unknown compatibility or eligibility disables direct actions.

Clicking an action opens a confirmation with account, container, expiry and effect. Confirming consumes a saved reset; it cannot be undone. The container rechecks runtime, account, grant binding, expiry and usage before sending. A very recent container-local usage proof can avoid duplicate throttled reads; it expires after 15 seconds and is tied to fresh identity, credentials and runtime. A throttled read can wait once for 60 seconds. A reset POST is never automatically retried.

An uncertain outcome remains reserved in the container's reset journal; do not delete this protection to force another attempt. The app refreshes usage to reconcile the result and keeps sanitized diagnostics locally. Reset testing in the repository is entirely synthetic.

## Appearance and troubleshooting

Use Settings for light/dark/system mode and native text zoom. Command +, Command -, and Command 0 also adjust zoom. Widgets have their own size-dependent typography.

- Docker unavailable: verify the executable path, context, engine and container name.
- Authentication unavailable: sign in using the runtime inside that container.
- Widget stale after upgrade: quit the app and run the provided installer, which refreshes extension registration and its process.
- Widget not in gallery: launch the installed packaged app once, refresh a source and reopen the gallery. Swift Package builds do not include the extension.
- Model missing: run Check models now in Sources; inspect account versus container support.
- New runtime: use read-only monitoring until its adapter is validated. Version labels do not guarantee private APIs never change.
