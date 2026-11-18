#!/bin/bash
# Export a clean initial Git history; never rewrite the local development repository.
set -euo pipefail
cd "$(dirname "$0")/.."
python3 scripts/audit-public.py
if ! git diff --quiet HEAD --; then
  echo "Commit the reviewed public tree before exporting."
  exit 1
fi
version=$(sed -n 's/.*MARKETING_VERSION: "\([^"]*\)"/\1/p' project.yml)
destination=${1:-"build/github/MockUsage-$version"}
if [ -e "$destination" ]; then
  echo "Destination already exists; choose a new empty destination."
  exit 1
fi
mkdir -p "$destination"
git archive HEAD | tar -xf - -C "$destination"
(
  cd "$destination"
  git init -b main
  git add .
  git -c user.name='Mock Usage Contributors' -c user.email='contributors@example.invalid' commit -m "Initial public source release $version"
  python3 scripts/audit-public.py --history
)
echo "Clean Git repository: $destination"
echo "No remote was configured and nothing was pushed."
