#!/usr/bin/env bash
# Tests for setup_worktree.sh tag/branch resolution
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# --- Setup: create a source repo with a branch and an annotated tag ---
git init "$TMPDIR/source" -q
pushd "$TMPDIR/source" >/dev/null
git commit --allow-empty -m "initial" -q
COMMIT_HASH=$(git rev-parse HEAD)
git tag -a v1.0.0 -m "release v1.0.0"
TAG_OBJ_HASH=$(git rev-parse refs/tags/v1.0.0)
git checkout -b feature/foo -q
git commit --allow-empty -m "feature" -q
BRANCH_HASH=$(git rev-parse HEAD)
popd >/dev/null

# Sanity: annotated tag object != commit
if [ "$TAG_OBJ_HASH" = "$COMMIT_HASH" ]; then
    echo "SETUP ERROR: tag object hash equals commit hash (lightweight tag?)"
    exit 2
fi

pass=0
fail=0

# Helper: set up a clean project root with bare repo and run setup_worktree.sh
# Returns LATEST_HASH via stdout
run_worktree_setup() {
    local branch="$1"
    local project_root="$TMPDIR/project_$(date +%N)"
    mkdir -p "$project_root/repos"

    # Init bare repo matching the layout setup_worktree.sh expects
    git init --bare "$project_root/repos/myrepo.git" -q
    git -C "$project_root/repos/myrepo.git" remote add testowner "file://$TMPDIR/source"
    git -C "$project_root/repos/myrepo.git" fetch testowner --tags -q

    # Copy the script so we can source it from the project root
    cp "$SCRIPT_DIR/setup_worktree.sh" "$project_root/"

    # Run in subshell with required env
    bash -c "
        set -euo pipefail
        cd '$project_root'
        repo_name=myrepo
        repo_owner=testowner
        branch='$branch'
        git_hash=''
        source ./setup_worktree.sh >/dev/null 2>&1
        echo \$LATEST_HASH
    "
}

run_test() {
    local name="$1" expected="$2" branch="$3"

    actual=$(run_worktree_setup "$branch") || actual="ERROR"

    if [ "$actual" = "$expected" ]; then
        echo "PASS: $name"
        pass=$((pass + 1))
    else
        echo "FAIL: $name"
        echo "  expected: $expected"
        echo "  got:      $actual"
        fail=$((fail + 1))
    fi
}

# --- Test: annotated tag resolves to COMMIT hash, not tag object hash ---
run_test "annotated tag resolves to commit hash" "$COMMIT_HASH" "v1.0.0"

# --- Test: branch resolves to correct commit hash ---
run_test "branch resolves to commit hash" "$BRANCH_HASH" "feature/foo"

echo ""
echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
