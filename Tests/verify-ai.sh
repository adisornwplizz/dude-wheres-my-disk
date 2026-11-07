#!/bin/bash
set -eu
cd "$(dirname "$0")/.."
scratch="$(mktemp -d "${TMPDIR:-/tmp}/dwmd-ai.XXXXXXXX")"
trap 'rm -rf "$scratch"' EXIT
xcrun swiftc -swift-version 5 -module-cache-path "$scratch/cache" Sources/TokenUsage.swift Sources/AIProvider.swift Sources/OllamaLocal.swift Sources/ModelCatalog.swift Tests/AIProviderVerify.swift -o "$scratch/check"
"$scratch/check"
xcrun swiftc -swift-version 5 -module-cache-path "$scratch/cache" Sources/TokenUsage.swift Sources/AIProvider.swift Sources/OllamaLocal.swift Sources/ModelCatalog.swift Tests/ModelCatalogVerify.swift -o "$scratch/check-models"
"$scratch/check-models"
