# Local widget validation

Validated on 18 November 2026 with the locally installed, ad-hoc signed 0.9.0 build.

The previous entity-backed parameters were retained by the editor but failed during timeline resolution with an App Intents entity-registration error. Labeled scalar account IDs now reach the timeline provider without depending on that entity registry.

| Size | Editor check | Timeline receipt |
| --- | --- | --- |
| Small | A specific Claude account was selected; the user confirmed it appeared on the desktop | Capacity 1, selected slots 1, rendered accounts 1 |
| Medium | Two different accounts were selected; reopening the editor retained their order | Capacity 2, selected slots 2, rendered accounts 2 |
| Large | Three accounts were selected; reopening the editor retained all three in the chosen order | Capacity 3, selected slots 3, rendered accounts 3 |

The automation surface sometimes selected a different desktop widget window after closing the editor. Therefore, medium and large desktop pixels were not independently captured as proof of the edited instance. Editor persistence and provider-side delivery were directly verified. The small widget's visible result was additionally confirmed by the user.

No real reset was submitted. All 59 Python tests and 13 Swift tests passed. Public assets use synthetic data. The app bundle and public Git history passed the privacy scanner, including a local-only list of private names.

## Restart and background-refresh verification (0.9.1)

On 18 November 2026, the app was restarted while preserving the existing desktop widgets. Five configuration fingerprints were compared before and after: one automatic small widget, one explicitly selected small widget, a two-account medium widget, an automatic large widget and a three-account large widget. All five retained their selection fingerprints, including account order. All five produced renewed timelines and newer source-capture timestamps.

The app window was closed for background operation. No refresh button or reset was used. All three source snapshots advanced during the observation interval. A temporary provider rate limit retried through the normal scheduler and subsequently returned fresh data. macOS still controls when a refreshed widget is painted; these measurements verify retained configuration, background collection and delivery to the widget timeline provider.

Local diagnostic history is bounded to 64 entries and contains selection hashes, counts and timestamps, never account names, raw account IDs, credentials or usage values. It is excluded from Git and release archives.
