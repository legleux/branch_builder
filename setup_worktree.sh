#!/usr/bin/env bash
# setup_worktree.sh — Manages a bare repo with multiple remotes and git worktrees.
#
# Sourced by build_image.sh (not executed directly). Maintains a single bare
# repo at repos/<repo_name>.git as a shared object store, with one git remote
# per fork owner. Creates or updates a detached worktree for the requested ref.
#
# Expected variables (set by caller before sourcing):
#   repo_owner  — GitHub org/user (e.g., "XRPLF", "tequdev")
#   repo_name   — repository name (e.g., "rippled")
#   branch      — branch or tag name to check out (used when git_hash is empty)
#   git_hash    — specific commit hash to check out (used when set; skips branch)
#   LOCAL_REPO  — optional path to a local clone; fetch from there instead of GitHub
#   LOCAL_DIRTY — when set with LOCAL_REPO, builds the working tree via stash create
#
# Exports:
#   WORKTREE_PATH — absolute path to the checked-out worktree directory
#   LATEST_HASH   — full commit SHA at HEAD of the worktree

set -euo pipefail

BARE_REPO="$PWD/repos/${repo_name}.git"

if [ -n "${LOCAL_REPO:-}" ]; then
    LOCAL_REPO="$(realpath "$LOCAL_REPO")"
    if ! git -C "$LOCAL_REPO" rev-parse --git-dir &>/dev/null; then
        echo "Error: LOCAL_REPO does not contain a git repo: ${LOCAL_REPO}"
        exit 1
    fi
    REMOTE_NAME="local-${repo_owner}"
    REMOTE_URL="$LOCAL_REPO"
    worktree_owner="${repo_owner}-local"
else
    REMOTE_NAME="${repo_owner}"
    REMOTE_URL="https://github.com/${repo_owner}/${repo_name}.git"
    worktree_owner="${repo_owner}"
fi

# =============================================================================
# Initialize bare repo
# =============================================================================
# The bare repo is created once and shared across all forks/branches. Each fork
# owner is added as a separate remote, so all objects are stored in one place.
if [ ! -d "$BARE_REPO" ]; then
    echo "Initializing bare repo at ${BARE_REPO}"
    git init --bare "$BARE_REPO"
fi

# =============================================================================
# Add or update remote for this fork owner
# =============================================================================
# Idempotent — adds if missing. In LOCAL_REPO mode, also updates the URL if
# it has moved between runs (local paths are not stable like GitHub URLs).
if ! git -C "$BARE_REPO" remote get-url "$REMOTE_NAME" &>/dev/null; then
    echo "Adding remote ${REMOTE_NAME} -> ${REMOTE_URL}"
    git -C "$BARE_REPO" remote add "$REMOTE_NAME" "$REMOTE_URL"
elif [ -n "${LOCAL_REPO:-}" ] && \
     [ "$(git -C "$BARE_REPO" remote get-url "$REMOTE_NAME")" != "$REMOTE_URL" ]; then
    echo "Updating remote ${REMOTE_NAME} -> ${REMOTE_URL}"
    git -C "$BARE_REPO" remote set-url "$REMOTE_NAME" "$REMOTE_URL"
fi

# =============================================================================
# Dirty working tree mode — capture staged + unstaged changes as a commit
# =============================================================================
# When LOCAL_DIRTY=1, uses git stash create to produce a commit object that
# captures tracked staged + unstaged changes without touching the working tree
# or the index. Falls back to HEAD if the tree is clean. Untracked files are
# NOT captured — use `git add -N <file>` to promote them to tracked intent-to-add.
if [ -n "${LOCAL_DIRTY:-}" ]; then
    if [ -z "${LOCAL_REPO:-}" ]; then
        echo "Error: LOCAL_DIRTY=1 requires LOCAL_REPO to be set"
        exit 1
    fi
    stash_sha=$(git -C "$LOCAL_REPO" stash create)
    if [ -z "$stash_sha" ]; then
        stash_sha=$(git -C "$LOCAL_REPO" rev-parse HEAD)
        echo "Working tree clean, building from HEAD (${stash_sha:0:12})"
    else
        echo "Captured dirty working tree as ${stash_sha:0:12}"
    fi
    # If the user didn't explicitly set BRANCH or TAG, derive from LOCAL_REPO's
    # current HEAD so image tags/labels reflect the real branch being built.
    if [ -z "${BRANCH:-}" ] && [ -z "${TAG:-}" ]; then
        local_branch=$(git -C "$LOCAL_REPO" rev-parse --abbrev-ref HEAD)
        if [ "$local_branch" = "HEAD" ]; then
            local_branch="detached-${stash_sha:0:8}"
        fi
        branch="$local_branch"
    fi
    # Pin the stash commit into a ref so it survives GC between runs.
    git -C "$BARE_REPO" fetch "$REMOTE_NAME" \
        "${stash_sha}:refs/local-builds/${repo_owner}/dirty" 2>&1 | sed 's/^/  /'
    git_hash="$stash_sha"
fi

if [ -n "${git_hash:-}" ]; then
    # =========================================================================
    # Commit hash mode
    # =========================================================================
    # When GIT_HASH is set, fetch that specific commit and create/update a
    # worktree at worktrees/<owner>/commit-<short-hash>. The worktree is
    # always in detached HEAD state.
    echo "Fetching commit ${git_hash} from ${REMOTE_NAME}"
    git -C "$BARE_REPO" fetch "$REMOTE_NAME" "$git_hash"

    short_hash="${git_hash:0:12}"
    WORKTREE_PATH="$PWD/worktrees/${worktree_owner}/commit-${short_hash}"
    LATEST_HASH="$git_hash"

    if [ ! -d "$WORKTREE_PATH" ]; then
        echo "Creating worktree for commit ${short_hash}"
        git -C "$BARE_REPO" worktree add "$WORKTREE_PATH" "$git_hash" --detach
    else
        CURRENT_HASH=$(git -C "$WORKTREE_PATH" rev-parse HEAD)
        if [ "$CURRENT_HASH" = "$git_hash" ]; then
            echo "Worktree already at commit ${short_hash}, skipping update."
        else
            echo "Updating worktree to commit ${short_hash}"
            git -C "$WORKTREE_PATH" checkout --detach "$git_hash"
        fi
    fi
else
    # =========================================================================
    # Branch/tag mode
    # =========================================================================
    # Fetches the ref from the remote, then resolves it. Tries as a branch
    # first (refs/remotes/<owner>/<branch>), then as a tag (refs/tags/<branch>).
    # This allows BRANCH=3.1.2 to work for tags without needing TAG= explicitly.
    #
    # The worktree directory uses the sanitized branch name (slashes → --).
    # Example: "ripple/smart-escrow" → worktrees/XRPLF/ripple--smart-escrow/
    #
    # Annotated tags are dereferenced to their underlying commit via ^{commit}.
    #
    # --tags ensures that when <branch> is actually a tag, it lands in
    # refs/tags/<branch> instead of only FETCH_HEAD (which is what plain
    # `git fetch <remote> <name>` does for tag refs).
    echo "Fetching ${REMOTE_NAME}/${branch}"
    git -C "$BARE_REPO" fetch --tags "$REMOTE_NAME" "$branch"

    # Resolve the ref — branch takes priority over tag if both exist.
    if git -C "$BARE_REPO" rev-parse --verify "refs/remotes/${REMOTE_NAME}/${branch}" &>/dev/null; then
        REMOTE_REF="refs/remotes/${REMOTE_NAME}/${branch}"
    elif git -C "$BARE_REPO" rev-parse --verify "refs/tags/${branch}" &>/dev/null; then
        REMOTE_REF="refs/tags/${branch}"
    else
        echo "Error: '${branch}' not found as branch or tag on ${REMOTE_NAME}"
        exit 1
    fi

    # Dereference to commit (handles annotated tags which point to tag objects).
    LATEST_HASH=$(git -C "$BARE_REPO" rev-parse "$REMOTE_REF^{commit}")

    sanitized_branch=$(echo "$branch" | sed 's|/|--|g')
    WORKTREE_PATH="$PWD/worktrees/${worktree_owner}/${sanitized_branch}"

    # Create or update the worktree. Skips checkout if already at the latest
    # commit (avoids unnecessary disk I/O on repeated builds).
    if [ ! -d "$WORKTREE_PATH" ]; then
        echo "Creating worktree at ${WORKTREE_PATH}"
        git -C "$BARE_REPO" worktree add "$WORKTREE_PATH" "$REMOTE_REF" --detach
    else
        CURRENT_HASH=$(git -C "$WORKTREE_PATH" rev-parse HEAD)
        if [ "$CURRENT_HASH" = "$LATEST_HASH" ]; then
            echo "Worktree already at latest (${LATEST_HASH:0:12}), skipping update."
        else
            echo "Updating worktree to ${LATEST_HASH:0:12}"
            git -C "$WORKTREE_PATH" checkout --detach "$REMOTE_REF"
        fi
    fi
fi

echo "Worktree ready: ${WORKTREE_PATH}"
echo "Commit: ${LATEST_HASH}"
