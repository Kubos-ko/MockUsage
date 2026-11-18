# GitHub publishing and security

## Repository and installation

The public repository is `Kubos-ko/MockUsage`. Download a release ZIP for the universal macOS app, or clone/download the source and follow README. Releases contain no account settings. Add your authenticated Docker containers in Sources after installation.

The published code and PNG previews use synthetic data. Private runtime files and local audit deny-lists are excluded. The Git author identity is a generic contributor with a reserved example address; fixture email addresses use reserved example domains. No personal certificate or signing key is needed by CI.

## Workflows

- **Validate:** audits tracked content and history, runs offline Python/Swift tests, builds the host and widget, scans the signed bundle, and uploads an installable ZIP plus SHA-256 checksum for seven days.
- **CodeQL:** scans Python and Swift on pushes and pull requests to main, and weekly. Swift uses the standard Intel macOS 15 runner with Xcode 16.4 because CodeQL traced builds do not support macOS/Xcode 27. This toolchain selection is separate from the minimum supported macOS version of the app.
- **Dependabot:** opens weekly update pull requests for pinned GitHub Actions.
- **Draft release:** manually dispatch with an existing version tag (for example `v0.9.1`). It verifies the version, audits, tests, builds and creates a draft GitHub Release. Review the draft before publishing it. It never enables automatic updates on users' Macs.

Actions are pinned to commit hashes, use minimal permissions and do not receive provider credentials. Untrusted pull requests do not publish releases. Local reset tests are synthetic: CI has no Docker sessions or real reset credentials.

## Free public-repository protections

GitHub's standard hosted Actions runners are free for public repositories. Public repositories support free CodeQL code scanning and automatic secret scanning. Enable secret-scanning push protection and Dependabot vulnerability alerts in repository settings as available. Do not select paid larger runners or purchase a security plan for these public-repository checks.

Secret scanning and custom privacy checks complement each other: GitHub does not recognize arbitrary company/account names as secrets. Run the local audit with a private term list before publication. No scanner proves that arbitrary sensitive text can never exist; review source, metadata and images as well.

Official references (checked 18 November 2026):

- [Actions billing](https://docs.github.com/en/actions/concepts/billing-and-usage)
- [GitHub security features](https://docs.github.com/en/code-security/getting-started/github-security-features)
- [Secret scanning](https://docs.github.com/en/code-security/concepts/secret-security/secret-scanning)
- [CodeQL action release notes](https://github.com/github/codeql-action/releases)

## Signing

Local and CI archives are ad-hoc signed. They do not contain an Apple Development or Developer ID certificate, Apple account, Team ID, provider account data or a machine identifier in the signature. They are not notarized. Build debug maps are stripped before signing so developer home paths are not shipped. A future notarized release needs separately managed Developer ID credentials; never commit those keys or certificates.
