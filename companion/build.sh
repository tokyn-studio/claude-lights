#!/usr/bin/env bash
#
# Packages the companion extension into a .vsix (requires node/npx).

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
npx --yes @vscode/vsce package --no-dependencies --allow-missing-repository
ls -la ./*.vsix
