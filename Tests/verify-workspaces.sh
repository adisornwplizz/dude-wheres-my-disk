#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
cases="$(mktemp -d "${TMPDIR:-/tmp}/dwmd-workspaces.XXXXXXXX")"
trap 'rm -rf "$cases"' EXIT
cases="$(cd "$cases" && pwd -P)"
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0
group="$cases/group"
for repo in "$group" "$group/backend" "$group/frontend" "$cases/standalone"; do
    git init -qb main "$repo"
    git -C "$repo" -c user.name=Fixture -c user.email=fixture@example.invalid commit -qm baseline --allow-empty
    git -C "$repo" worktree add -qb feature "$cases/$(basename "$repo")-linked"
done
mkdir -p "$group/.hidden/.git" "$group/ordinary/deeper/.git" "$group/node_modules/dependency/.git"
ln -s "$cases/standalone" "$group/other-repository"
swiftc -swift-version 5 -module-cache-path "$cases/cache" Sources/WorktreeActivity.swift Sources/WorkspaceStorage.swift Sources/Inventory.swift Sources/CleanupReview.swift Sources/WorkspaceLibrary.swift Tests/WorkspaceVerify.swift -o "$cases/check"
"$cases/check" "$group"
swiftc -module-cache-path "$cases/cache" Sources/WorktreeActivity.swift Tests/ActivityVerify.swift -o "$cases/check-activity"
"$cases/check-activity"
