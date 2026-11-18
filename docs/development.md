# Development and release

## Repository layout

- Sources/UsageCore: models, configuration migration, selection policy, widget snapshot transport.
- Sources/MockUsage: host UI, store, menu bar, Docker bridge and collector resource.
- Widget: App Intent configuration, timeline and size-aware SwiftUI rendering.
- Tests: synthetic Python provider fixtures, Swift core tests and offline Docker-substitute integration tests.
- Config and project.yml: bundle metadata, entitlements and XcodeGen configuration.
- scripts: build, install, package, audit and clean-public-export helpers.

All authored code, comments, UI strings and documentation are English. Do not commit live credentials, account exports, personal diagnostics, generated caches or private container configuration.

## Validation

```sh
python3 -m unittest discover -s Tests -v
swift test
python3 scripts/audit-public.py
bash scripts/build.sh
```

Tests never perform a live reset. The integration suite uses a temporary Docker substitute that rejects reset/model commands and network/credential access. It covers upgrades, rollback, background retry policy and stale-confirmation blocking. Provider tests mock transport, including successful and uncertain reset outcomes.

## Add a runtime version

1. Inspect its read-only schemas and identity behavior.
2. If unchanged, add the exact version binding only after fixture validation.
3. If changed, add a new adapter implementation and ID; preserve earlier bindings.
4. Test usage, catalogs, resets, unknown versions, unsupported versions and older runtimes.
5. Update the support matrix and changelog, then ship a new app release.

Never use a real reset as an automatic test. A provider rejection or uncertain response is not permission to repeat a reset.

## Version policy

project.yml is the version source of truth for host and widget. Increase patch for fixes, minor for compatible features and major for breaking behavior/configuration changes. Increase the build number for each distributed build. XcodeGen regenerates the checked-in Xcode project.

## Packages and installation

`build.sh` compiles the host and extension, stages outside cloud-synced directories, strips extended attributes, ad-hoc signs both bundles, verifies signatures and creates build/MockUsage.zip. `install.sh` installs the bundle in user Applications and refreshes the extension process after upgrades.

`package-release.sh` creates a versioned native-architecture ZIP and checksum in dist. It does not claim universal architecture or notarization. Publish binaries as GitHub Release assets; source Git history stays small and reviewable. A public distributor may replace ad-hoc signing with its own Developer ID/notarization workflow; signing credentials must be CI secrets, never repository files.

## GitHub preparation

Run the audit on the reviewed working tree. `--history` additionally checks historical blobs without printing matched values. If private development data ever entered history, do not assume deleting the current file removes it from Git.

`export-public.sh` exports the committed tracked tree into a fresh Git repository, then scans its complete history. It preserves the local development repository, excludes ignored runtime/build files and does not configure a remote or push. Review the export, choose a license, then attach your own GitHub remote. This avoids destructive rewriting of local development history.

The GitHub Actions validation workflow has read-only repository permissions, uses no provider secrets, runs tests, builds and uploads a locally signed artifact. It is not an auto-update or publishing service.

## Release privacy checks

The local release strips debug maps before signing and scans all bundle files. `scripts/package-release.sh` labels the archive `universal`, matching its Intel and Apple Silicon slices. Keep obsolete release archives out of GitHub Releases if they were built before this privacy check.

Use `python3 scripts/audit-public.py --history` to include author/committer metadata and messages. An optional local-only `--private-terms` file can reject private organization or account names without embedding them in source. Never commit that file. Public history uses a generic contributor identity and reserved example email.

Public UI previews are rendered from synthetic data using `python3 scripts/render-previews.py`; see `docs/images/README.md`.
