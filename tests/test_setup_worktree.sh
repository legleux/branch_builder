#!/usr/bin/env bash
# Tests for setup_worktree.sh tag/branch resolution
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# --- Setup: create a source repo with a branch, an annotated tag, and a tracked file ---
git init "$TMPDIR/source" -q
pushd "$TMPDIR/source" >/dev/null
git config user.email "test@example.com"
git config user.name "Test"
echo "original" > tracked.txt
git add tracked.txt
git commit -m "initial" -q
COMMIT_HASH=$(git rev-parse HEAD)
git tag -a v1.0.0 -m "release v1.0.0"
TAG_OBJ_HASH=$(git rev-parse refs/tags/v1.0.0)
git checkout -b feature/foo -q
git commit --allow-empty -m "feature" -q
BRANCH_HASH=$(git rev-parse HEAD)
git checkout master 2>/dev/null || git checkout main 2>/dev/null || git checkout -b main -q
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

# =============================================================================
# LOCAL_REPO / LOCAL_DIRTY mode
# =============================================================================

# Helper: run setup_worktree.sh in local mode. Echoes "<LATEST_HASH>|<WORKTREE_PATH>|<tracked_contents>".
run_local_setup() {
    local local_repo="$1" local_dirty="${2:-}" branch="${3:-}" branch_env="${4:-}" tag_env="${5:-}"
    local project_root="$TMPDIR/project_local_$(date +%N)"
    mkdir -p "$project_root/repos"
    cp "$SCRIPT_DIR/setup_worktree.sh" "$project_root/"

    bash -c "
        set -euo pipefail
        cd '$project_root'
        export LOCAL_REPO='$local_repo'
        export LOCAL_DIRTY='$local_dirty'
        export BRANCH='$branch_env'
        export TAG='$tag_env'
        repo_name=myrepo
        repo_owner=testowner
        branch='$branch'
        git_hash=''
        source ./setup_worktree.sh >/dev/null 2>&1
        tracked=''
        [ -f \"\$WORKTREE_PATH/tracked.txt\" ] && tracked=\$(cat \"\$WORKTREE_PATH/tracked.txt\")
        echo \"\$LATEST_HASH|\$WORKTREE_PATH|\$tracked\"
    "
}

# --- Test: LOCAL_REPO + committed branch ---
out=$(run_local_setup "$TMPDIR/source" "" "feature/foo" "feature/foo" "") || out="ERROR"
IFS='|' read -r got_hash got_path got_tracked <<< "$out"
if [ "$got_hash" = "$BRANCH_HASH" ] && [[ "$got_path" == *"/worktrees/testowner-local/feature--foo" ]]; then
    echo "PASS: LOCAL_REPO committed branch uses -local namespace and correct hash"
    pass=$((pass + 1))
else
    echo "FAIL: LOCAL_REPO committed branch"
    echo "  expected hash $BRANCH_HASH, path .../worktrees/testowner-local/feature--foo"
    echo "  got: $out"
    fail=$((fail + 1))
fi

# --- Test: LOCAL_DIRTY=1 on clean working tree falls back to HEAD ---
out=$(run_local_setup "$TMPDIR/source" "1" "" "" "") || out="ERROR"
IFS='|' read -r got_hash got_path got_tracked <<< "$out"
# After checkout back to master/main, HEAD is COMMIT_HASH (master branch)
if [ "$got_hash" = "$COMMIT_HASH" ] && [ "$got_tracked" = "original" ]; then
    echo "PASS: LOCAL_DIRTY=1 on clean tree falls back to HEAD"
    pass=$((pass + 1))
else
    echo "FAIL: LOCAL_DIRTY=1 clean fallback"
    echo "  expected hash $COMMIT_HASH, tracked 'original'"
    echo "  got: $out"
    fail=$((fail + 1))
fi

# --- Test: LOCAL_DIRTY=1 with unstaged change captures working tree ---
echo "modified content" > "$TMPDIR/source/tracked.txt"
out=$(run_local_setup "$TMPDIR/source" "1" "" "" "") || out="ERROR"
IFS='|' read -r got_hash got_path got_tracked <<< "$out"
if [ "$got_hash" != "$COMMIT_HASH" ] && [ "$got_hash" != "$BRANCH_HASH" ] && [ "$got_tracked" = "modified content" ]; then
    echo "PASS: LOCAL_DIRTY=1 with unstaged change captures the modification"
    pass=$((pass + 1))
else
    echo "FAIL: LOCAL_DIRTY=1 with unstaged change"
    echo "  expected: new hash (not \$COMMIT_HASH / \$BRANCH_HASH) with tracked='modified content'"
    echo "  got: $out"
    fail=$((fail + 1))
fi
# Restore clean state for subsequent runs
git -C "$TMPDIR/source" checkout -- tracked.txt 2>/dev/null || true

# --- Test: LOCAL_DIRTY=1 without LOCAL_REPO errors out ---
project_root="$TMPDIR/project_dirty_only"
mkdir -p "$project_root/repos"
cp "$SCRIPT_DIR/setup_worktree.sh" "$project_root/"
set +e
out=$(bash -c "
    set -euo pipefail
    cd '$project_root'
    unset LOCAL_REPO
    export LOCAL_DIRTY=1
    repo_name=myrepo
    repo_owner=testowner
    branch='develop'
    git_hash=''
    source ./setup_worktree.sh 2>&1
" )
rc=$?
set -e
if [ "$rc" -ne 0 ] && echo "$out" | grep -q "LOCAL_DIRTY"; then
    echo "PASS: LOCAL_DIRTY=1 without LOCAL_REPO exits with error"
    pass=$((pass + 1))
else
    echo "FAIL: LOCAL_DIRTY=1 without LOCAL_REPO should error"
    echo "  rc=$rc, output: $out"
    fail=$((fail + 1))
fi

echo ""
echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
