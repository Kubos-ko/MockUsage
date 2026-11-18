# Security and private data

## Credentials

Provider OAuth tokens stay in their existing container homes. The collector never exports token values or authorization headers. Do not paste credentials into issue reports or embed them in images/Compose files. Docker access itself grants substantial control over containers; protect the Docker engine and socket.

## Local private files

Configuration, account catalogs, usage snapshots, widget choices and diagnostics are local data. They are not included in the app archive or clean public export. Runtime JSON files, environment files, private keys and local diagnostics are ignored by Git. The repository starts new users with no hard-coded account names or containers.

The app stores an account fingerprint for grouping/selection. It is not an OAuth credential, but it still belongs in local runtime data. Reset journals prevent repeating uncertain submissions; do not delete them to force retries.

## Public-source audit

Run `python3 scripts/audit-public.py` before committing/releasing, and `--history` before publishing existing history. The scanner checks common token/private-key patterns, private runtime filenames and personal home paths. It prints locations and categories, never matched values. It is a best-effort check, not proof that arbitrary secrets cannot exist. Review diffs and use GitHub secret scanning where available.

Private development history must not be pushed. Use the clean export helper when needed. Git author metadata and any files you add after export should also be reviewed before publication.

## Reporting

Report a minimal reproduction using synthetic account names and redacted logs. Never include provider tokens, raw account identifiers, grant bindings, credential files or full container environments. For a suspected credential exposure, revoke the credential with its provider and remove it from all published history before republishing.

## Local signing and release privacy

The local build uses an ad-hoc code signature (`codesign --sign -`). Its signature has no signing certificate, Apple account or Team Identifier. The code-directory hash identifies the built code, not the computer or a provider account. This is not Developer ID signing or notarization.

Build debug maps can contain developer home paths even when source code contains none. The packaging script strips these maps before signing, then scans the entire app bundle. Runtime settings and credentials are never copied into the archive. The archive is universal (Apple Silicon and Intel).

The audit also checks commit messages and author/committer metadata with `--history`. Reserved example email addresses in tests and contributor metadata are synthetic. For additional organization/account names, pass `--private-terms /path/to/local-only-terms.txt`; this file must stay outside tracked content. Findings print categories, never matched values.
