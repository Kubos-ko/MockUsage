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
