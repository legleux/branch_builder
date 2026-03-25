#!/usr/bin/env bash
# setup_worktree.sh — Manages a bare repo with multiple remotes and git worktrees.
# Sourced by build_image.sh. Expects: repo_owner, repo_name, branch (or git_hash).
# Exports: WORKTREE_PATH, LATEST_HASH

set -euo pipefail

BARE_REPO="$PWD/repos/${repo_name}.git"
REMOTE_NAME="${repo_owner}"
REMOTE_URL="https://github.com/${repo_owner}/${repo_name}.git"

# --- Init bare repo if needed ---
if [ ! -d "$BARE_REPO" ]; then
    echo "Initializing bare repo at ${BARE_REPO}"
    git init --bare "$BARE_REPO"
fi

# --- Add remote if needed ---
if ! git -C "$BARE_REPO" remote get-url "$REMOTE_NAME" &>/dev/null; then
    echo "Adding remote ${REMOTE_NAME} -> ${REMOTE_URL}"
    git -C "$BARE_REPO" remote add "$REMOTE_NAME" "$REMOTE_URL"
fi

if [ -n "${git_hash:-}" ]; then
    # --- Commit hash mode ---
    echo "Fetching commit ${git_hash} from ${REMOTE_NAME}"
    git -C "$BARE_REPO" fetch "$REMOTE_NAME" "$git_hash"

    short_hash="${git_hash:0:12}"
    WORKTREE_PATH="$PWD/worktrees/${repo_owner}/commit-${short_hash}"
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
    # --- Branch mode ---
    echo "Fetching ${REMOTE_NAME}/${branch}"
    git -C "$BARE_REPO" fetch "$REMOTE_NAME" "$branch"

    REMOTE_REF="refs/remotes/${REMOTE_NAME}/${branch}"
    LATEST_HASH=$(git -C "$BARE_REPO" rev-parse "$REMOTE_REF")

    sanitized_branch=$(echo "$branch" | sed 's|/|--|g')
    WORKTREE_PATH="$PWD/worktrees/${repo_owner}/${sanitized_branch}"

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
