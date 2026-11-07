#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
scratch="$(mktemp -d "${TMPDIR:-/tmp}/dwmd-storage.XXXXXXXX")"
trap 'rm -rf "$scratch"' EXIT
xcrun swiftc -swift-version 5 -module-cache-path "$scratch/cache" Sources/WorkspaceStorage.swift Tests/StorageVerify.swift -o "$scratch/check"
"$scratch/check"
