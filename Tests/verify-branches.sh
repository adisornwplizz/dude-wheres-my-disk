#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
cases="$(mktemp -d "${TMPDIR:-/tmp}/dwmd-branches.XXXXXXXX")"
trap 'rm -rf "$cases"' EXIT
cases="$(cd "$cases" && pwd -P)"
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0
remote="$cases/upstream bare.git"
repo="$cases/main checkout"
git init --quiet --bare --initial-branch=main "$remote"
git init --quiet --initial-branch=main "$repo"
git -C "$repo" config user.name Fixture
git -C "$repo" config user.email fixture@example.invalid
git -C "$repo" commit --quiet --allow-empty -m base
git -C "$repo" remote add origin "$remote"
git -C "$repo" push --quiet -u origin main
git -C "$repo" remote set-head origin -a >/dev/null
for name in archive present checked unmerged recreated moved offline occupancy collision; do
    git -C "$repo" branch -- "$name"
    git -C "$repo" push --quiet -u origin "$name"
done
git -C "$repo" switch -qc advanced
git -C "$repo" push --quiet -u origin advanced
git -C "$repo" commit --quiet --allow-empty -m "integrated after last push"
git -C "$repo" switch --quiet main
git -C "$repo" merge --quiet --ff-only advanced
git --git-dir="$remote" update-ref -d refs/heads/advanced
git -C "$repo" branch no-upstream
git -C "$repo" branch renamed
git -C "$repo" push --quiet -u origin renamed:remote-topic
for name in archive checked unmerged recreated moved offline occupancy remote-topic; do
    git --git-dir="$remote" update-ref -d "refs/heads/$name"
done
git -C "$repo" worktree add --quiet "$cases/checked checkout" checked
git -C "$repo" switch --quiet unmerged
git -C "$repo" commit --quiet --allow-empty -m 'still unique'
git -C "$repo" switch --quiet main
git -C "$repo" remote add unavailable "$cases/unavailable.git"
git -C "$repo" config branch.offline.remote unavailable
git -C "$repo" branch --set-upstream-to=origin/main collision >/dev/null
swiftc -swift-version 5 -module-cache-path "$cases/cache" Sources/Inventory.swift Sources/WorkspaceStorage.swift Sources/WorktreeActivity.swift Sources/BranchCleanup.swift Tests/BranchCleanupVerify.swift -o "$cases/check"
"$cases/check" "$repo" "$remote" "$cases"
