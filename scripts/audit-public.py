#!/usr/bin/env python3
"""Check tracked content without printing matched secrets. Not a security guarantee."""
import argparse
import pathlib
import re
import subprocess
import sys

PATTERNS = {
    "private-key": rb"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----",
    "provider-key": rb"\bsk-(?:ant-|proj-)?[A-Za-z0-9_-]{24,}",
    "github-token": rb"\b(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,})",
    "aws-access-key": rb"\b(?:AKIA|ASIA)[A-Z0-9]{16}\b",
    "jwt": rb"\beyJ[A-Za-z0-9_-]{12,}\.[A-Za-z0-9_-]{12,}\.[A-Za-z0-9_-]{12,}",
    "personal-home-path": rb"/Users/(?!Shared(?:/|\b)|example(?:/|\b))[A-Za-z0-9_.-]+/",
}
PRIVATE_NAMES = {".env", "auth.json", ".credentials.json", "configuration.json", "usage-cache.json",
                 "model-catalogs.json", "widget-usage.json", "widget-read-receipt.json", "widget-timeline-receipt.json", "last-reset-diagnostic.json"}


def git(*args):
    return subprocess.check_output(["git", *args])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--history", action="store_true", help="Also inspect historical blobs, without rewriting history")
    parser.add_argument("--bundle", type=pathlib.Path, help="Inspect a built app bundle instead of Git")
    parser.add_argument("--private-terms", type=pathlib.Path, help="Local-only newline-separated names to reject; never commit this file")
    args = parser.parse_args()
    private_terms = [line.strip().lower() for line in args.private_terms.read_bytes().splitlines() if line.strip()] if args.private_terms else []
    def categories(data):
        result = [kind for kind, expression in PATTERNS.items() if re.search(expression, data)]
        if any(term in data.lower() for term in private_terms):
            result.append("private-term")
        for email in re.findall(rb"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}", data):
            domain = email.rsplit(b"@", 1)[1].lower()
            if domain not in {b"example.com", b"example.test", b"example.invalid"}:
                result.append("non-example-email")
                break
        return result
    if args.bundle:
        findings = [(str(path.relative_to(args.bundle)), kind) for path in args.bundle.rglob("*")
                    if path.is_file() for kind in categories(path.read_bytes())]
        for path, kind in findings:
            print(f"bundle: {path}: {kind}")
        print(f"Bundle audit: {len(findings)} findings. Matched values are never printed.")
        return bool(findings)
    findings = []
    entries = [(None, p) for p in git("ls-files", "-z").decode().split("\0") if p]
    if args.history:
        for oid in git("rev-list", "--all").decode().splitlines():
            for kind in categories(git("cat-file", "commit", oid)):
                findings.append(("commit-metadata", oid[:12], kind))
        for row in git("rev-list", "--objects", "--all").decode().splitlines():
            oid, _, path = row.partition(" ")
            if path and git("cat-file", "-t", oid).strip() == b"blob":
                entries.append((oid, path))
    seen = set()
    for oid, path in entries:
        if (oid, path) in seen:
            continue
        seen.add((oid, path))
        file = pathlib.Path(path)
        if not oid and not file.is_file():
            continue
        source = "history" if oid else "working-tree"
        if file.name in PRIVATE_NAMES or path.startswith(("Diagnostics/", ".local-diagnostics/")) or file.suffix.lower() in {".pem", ".p12", ".pfx", ".key"}:
            findings.append((source, path, "private-file"))
        data = git("cat-file", "blob", oid) if oid else file.read_bytes()
        for kind in categories(data + b"\n" + path.encode()):
            findings.append((source, path, kind))
    for source, path, kind in sorted(set(findings)):
        print(f"{source}: {path}: {kind}")
    print(f"Checked {len(seen)} tracked/current or historical entries; {len(set(findings))} findings. Matched values are never printed.")
    return bool(findings)


if __name__ == "__main__":
    sys.exit(main())
