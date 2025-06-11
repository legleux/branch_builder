#!/usr/bin/env bash
set -euo pipefail

# Debugging output
set -x

# Configurable defaults
DEFAULT_REPO_OWNER="XRPLF"
DEFAULT_REPO_NAME="rippled"
DEFAULT_REF="develop"

# Accept parameters
REPO_ARG="${1:-}"  # optional repo or ref
REF_ARG="${2:-}"   # optional ref if repo is provided explicitly

# Determine repo and ref
if [[ "$REPO_ARG" == */* ]]; then
    REPO_FULL="$REPO_ARG"
    REF="${REF_ARG:-$DEFAULT_REF}"
else
    REPO_FULL="$DEFAULT_REPO_OWNER/$DEFAULT_REPO_NAME"
    REF="${REPO_ARG:-$DEFAULT_REF}"
fi

REPO_OWNER="${REPO_FULL%%/*}"
REPO_NAME="${REPO_FULL##*/}"

REPO_URL="https://github.com/$REPO_FULL.git"
BARE_REPO_DIR="repos/$REPO_OWNER/${REPO_NAME}.git"
WORKTREES_BASE="repos/$REPO_OWNER/$REPO_NAME"
WORKTREE_DIR="$WORKTREES_BASE/$REF"

mkdir -p "$WORKTREES_BASE"

# Clone the bare repo only if it doesn't already exist
if [ ! -f "$BARE_REPO_DIR/HEAD" ]; then
    echo "Cloning bare repo into $BARE_REPO_DIR"
    git clone --bare "$REPO_URL" "$BARE_REPO_DIR"
fi

# Fetch latest refs
if ! git --git-dir="$BARE_REPO_DIR" rev-parse --verify --quiet "$REF^{commit}"; then
    if git --git-dir="$BARE_REPO_DIR" ls-remote --exit-code --tags origin "$REF" >/dev/null 2>&1; then
        echo "Fetching tag $REF"
        git --git-dir="$BARE_REPO_DIR" fetch --depth=1 origin "refs/tags/$REF:refs/tags/$REF"
    elif git --git-dir="$BARE_REPO_DIR" ls-remote --exit-code origin "$REF" >/dev/null 2>&1; then
        echo "Fetching branch $REF"
        git --git-dir="$BARE_REPO_DIR" fetch --depth=1 origin "$REF:$REF"
    else
        echo "Fetching commit SHA $REF"
        git --git-dir="$BARE_REPO_DIR" fetch origin "$REF"
    fi
fi

COMMIT_SHA=$(git --git-dir="$BARE_REPO_DIR" rev-parse --verify --quiet "$REF^{commit}" || true)
if [ -z "$COMMIT_SHA" ]; then
    echo "ERROR: Could not resolve ref '$REF' to a commit."
    exit 1
fi

# Add worktree if needed
if [ -d "$WORKTREE_DIR/.git" ] || [ -f "$WORKTREE_DIR/.git" ]; then
    echo "Worktree already exists at $WORKTREE_DIR"
else
    if git --git-dir="$BARE_REPO_DIR" worktree list | grep -q " $WORKTREE_DIR "; then
        echo "Removing stale worktree entry for $WORKTREE_DIR"
        git --git-dir="$BARE_REPO_DIR" worktree remove --force "$WORKTREE_DIR"
    fi
    echo "Adding worktree for $COMMIT_SHA at $WORKTREE_DIR"
    git --git-dir="$BARE_REPO_DIR" worktree add "$WORKTREE_DIR" "$COMMIT_SHA"
fi

cd "$WORKTREE_DIR"
echo "✅ Checked out $COMMIT_SHA at $WORKTREE_DIR"
