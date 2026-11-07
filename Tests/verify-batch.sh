#!/bin/bash
set -eu
cd "$(dirname "$0")/.."
scratch="$(mktemp -d "${TMPDIR:-/tmp}/dwmd-batch.XXXXXXXX")"
trap 'rm -rf "$scratch"' EXIT
sources=(Sources/TokenUsage.swift Sources/AIProvider.swift Sources/OllamaLocal.swift Sources/ModelCatalog.swift Sources/ProviderKeys.swift
         Sources/AIViews.swift Sources/StudioStyle.swift Sources/WorkspaceLibrary.swift Sources/WorkspaceStorage.swift
         Sources/WorktreeActivity.swift Sources/Inventory.swift Sources/CleanupReview.swift Sources/AllWorkspacesAnalysis.swift)
xcrun swiftc -swift-version 5 -module-cache-path "$scratch/cache" "${sources[@]}" Tests/BatchEvidenceVerify.swift -o "$scratch/check"
"$scratch/check"
