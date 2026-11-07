#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
case_dir="$(mktemp -d "${TMPDIR:-/tmp}/dwmd-verify.XXXXXXXX")"
trap 'rm -rf "$case_dir"' EXIT
case_dir="$(cd "$case_dir" && pwd -P)"

export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
export GIT_TERMINAL_PROMPT=0
mkdir "$case_dir/trees"
repo="$case_dir/repo with spaces"
git init -qb main "$repo"
git -C "$repo" config user.name "Worktree Fixture"
git -C "$repo" config user.email "fixture@example.invalid"
printf 'local-only/\nnode_modules/\n.env\n/dist/\n/.yarn/cache/\n/.yarn/install-state.gz\n' > "$repo/.gitignore"
printf 'tracked seed\n' > "$repo/readme"
git -C "$repo" add .
git -C "$repo" commit -qm "Seed"

for name in "clean branch" dirty ignored locked unmerged stale generated concealed merging nested; do
    git -C "$repo" worktree add -qb "${name// /-}" "$case_dir/trees/$name" main
done
git -C "$repo" worktree add -q --detach "$case_dir/trees/detached" main
printf 'edited tracked file\n' > "$case_dir/trees/dirty/readme"
git -C "$case_dir/trees/concealed" update-index --assume-unchanged readme
printf 'edit hidden from status\n' > "$case_dir/trees/concealed/readme"
mkdir "$case_dir/trees/ignored/local-only"
printf 'private local config\n' > "$case_dir/trees/ignored/local-only/settings"
mkdir -p "$case_dir/trees/generated/node_modules/a-package"
printf 'package payload\n' > "$case_dir/trees/generated/node_modules/a-package/index.js"
child_repo="$case_dir/independent child"
git init -qb main "$child_repo"
git -C "$child_repo" -c user.name=Fixture -c user.email=fixture@example.invalid commit -qm "Child seed" --allow-empty
git -C "$child_repo" worktree add -qb child-task "$case_dir/trees/nested/node_modules/.jobs/frontend"
ln -s "$child_repo" "$case_dir/trees/generated/node_modules/linked-package"
git -C "$repo" worktree lock "$case_dir/trees/locked"
git -C "$case_dir/trees/unmerged" commit -qm "Unmerged work" --allow-empty
git -C "$case_dir/trees/merging" merge -q --no-ff --no-commit unmerged

git -C "$repo" worktree add -qb confidential-squash "$case_dir/trees/squashed" main
for i in 1 2 3 4 5; do
    printf '%s\n' "$i" >> "$case_dir/trees/squashed/secret-tracked-name"
    git -C "$case_dir/trees/squashed" add secret-tracked-name
    git -C "$case_dir/trees/squashed" commit -qm "private commit $i"
done
git -C "$repo" merge --squash -q confidential-squash
git -C "$repo" commit -qm "single aggregate commit"
git -C "$repo" worktree add -qb partial-integration "$case_dir/trees/partial" confidential-squash
printf 'extra change\n' >> "$case_dir/trees/partial/secret-tracked-name"
git -C "$case_dir/trees/partial" commit -qam "still unique"
printf 'later main content\n' > "$repo/later"
git -C "$repo" add later
git -C "$repo" commit -qm "Advance main beyond squash"
mkdir -p "$case_dir/trees/squashed/.yarn/cache" "$case_dir/trees/squashed/dist"
printf 'cache' > "$case_dir/trees/squashed/.yarn/cache/package.zip"
printf 'state' > "$case_dir/trees/squashed/.yarn/install-state.gz"
printf 'built' > "$case_dir/trees/squashed/dist/main.js"

swiftc -module-cache-path "$case_dir/swift-cache" Sources/WorktreeActivity.swift Sources/WorkspaceStorage.swift Sources/Inventory.swift Tests/Verify.swift -o "$case_dir/check"
"$case_dir/check" "$repo" "$child_repo"
git -C "$repo" show-ref --verify --quiet refs/heads/clean-branch
git -C "$repo" show-ref --verify --quiet refs/heads/generated
git -C "$repo" show-ref --verify --quiet refs/heads/confidential-squash
test -f "$case_dir/trees/ignored/local-only/settings"
test -f "$case_dir/trees/stale/new work.txt"
test -f "$case_dir/trees/nested/node_modules/.jobs/frontend/.git"
git -C "$child_repo" rev-parse --verify HEAD >/dev/null
printf 'Verified worktree classification, nested checkout protection, deletion guards, disk effects, and branch retention.\n'
