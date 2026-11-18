# Architecture

## Data path

`SwiftUI / menu bar → UsageStore → DockerBridge → docker exec → bundled Python collector → provider API`

The host receives normalized usage, account fingerprints, reset eligibility and runtime metadata. Credentials remain in the container. DockerBridge uses argument arrays rather than interpolated shell commands, validates source names, bounds process output and applies timeouts. Collector protocol 1 is checked before decoding.

UsageStore runs on the main actor, owns independent source states and a timer in common run-loop modes, groups verified account identities, persists settings/cache, and updates the widget snapshot. AppDelegate starts monitoring independently of dashboard visibility. MenuBarController observes store changes; the same selected accounts feed its bar image and percentage labels.

## Adapters

`RUNTIME_ADAPTERS` maps exact versions to stable adapter IDs. `ADAPTERS` supplies `collect()`, `models(client_version)` and `redeem(intent)`. Existing bindings must not be silently repointed when introducing a new API implementation. `READ_ONLY_FALLBACKS` handles unknown versions. `UNSUPPORTED_RUNTIMES` records proven incompatibilities with reasons.

Current implementations are CodexWhamV1Adapter and ClaudeOAuthV1Adapter. Common transport and reset safeguards are shared; modifications require the full regression suite. OAuth usage endpoints are private provider interfaces and may evolve independently of runtime releases.

## Widget path

The host writes owner-only normalized snapshots to the widget extension's sandbox at `~/Library/Containers/local.mockusage.app.widget/Data/Library/Application Support/MockUsage/widget-usage.json`. Widget code reads relative to its own sandbox home. No App Group is required for this tested local unsandboxed-host setup.

WidgetKit uses AppIntentConfiguration, a WidgetConfigurationIntent and an EntityQuery backed only by that snapshot. Family-dependent parameter summaries expose 1/2/3 selection slots. The shared DisplaySelection policy preserves chosen order, removes duplicates, respects capacity and never replaces a missing explicit selection with another account. Old all-empty configurations use automatic selection. The renderer limits rows and provides a dense three-account layout.

Host refreshes request timeline reloads; WidgetKit schedules delivery. Future entries mark stale data even if the host stops. A minimal widget-read receipt records read time and account count for local diagnosis.

## Storage

Host files under `~/Library/Application Support/MockUsage` include configuration.json, usage-cache.json, model-catalogs.json and optional last-reset-diagnostic.json. They are private runtime data, not release assets. Live reset inventory is stripped from host usage caches and widget snapshots.

Each container may contain a reset journal and a short-lived Claude preflight cache in its provider home. The preflight record contains a credential fingerprint, not a token, and expires after 15 seconds. A fresh profile, runtime and confirmation binding must match before reuse. The record is removed after submission.

## Reset lifecycle

Explicit UI confirmation → host freshness/runtime/grant checks → container runtime check → fresh profile and usage validation → durable reservation → one POST → normalized outcome → usage reconciliation.

The reservation is written and synced before POST. Unknown outcomes block duplicates across restarts. Repeated read throttling never triggers a POST retry. Confirmation expiry is evaluated after any preflight wait. Diagnostic output uses an allowlist of stage, outcome, HTTP status, bounded delay and known reason codes; no arbitrary server messages or credentials are exported.

## Reference

The configurable widget follows Apple's [Making a configurable widget](https://developer.apple.com/documentation/widgetkit/making-a-configurable-widget) and [family-dependent parameter summaries](https://developer.apple.com/documentation/appintents/parametersummaryswitchcondition/init(_:_:)-4vxvs). These are implementation references, not claims that the local snapshot transport is suitable for App Store distribution.
