#!/usr/bin/env bash
# build_image.sh — Main entry point for building xrpld Docker images.
#
# Orchestrates the full build pipeline:
#   1. Load environment defaults from ./env
#   2. Validate mutually-exclusive ref inputs (BRANCH, TAG, GIT_HASH)
#   3. Set up a git worktree for the target source (via setup_worktree.sh)
#   4. If TAG is set, validate it's a real tag and resolve the underlying
#      release branch (e.g., TAG=3.1.2 → branch=release-3.1) so the
#      Dockerfile's fake .git plumbing records the correct branch name
#   5. Apply host-side patches from branches/<owner>/<sanitized-branch>/
#   6. Resolve a per-branch Dockerfile override if one exists
#   7. Assemble Docker build args, labels, tags, and resource limits
#   8. Print a build summary and either execute or dry-run the build
#
# Inputs (environment variables — see README.md for full list):
#   REPO_OWNER, REPO_NAME  — GitHub fork/repo (default: XRPLF/rippled)
#   BRANCH | TAG | GIT_HASH — mutually exclusive ref to build
#   ADD_TAGS                — comma-separated extra Docker tag suffixes
#                             (plain names → $IMAGE:<name>, paths with / → used as-is)
#   ADD_LABELS              — comma-separated extra Docker labels (key=value)
#   DRY_RUN, PUSH, MEM_LIMIT, NPROC, etc.
#
# Outputs:
#   A Docker image loaded locally (or pushed to registry if PUSH=true).

set +o xtrace

# =============================================================================
# Terminal colors
# =============================================================================
# Falls back to no color when stdout isn't a terminal (piped output, CI).
if [ -t 1 ]; then
    C_CYAN='\033[1;36m'    # bold cyan — section headers
    C_WHITE='\033[1;37m'   # bold white — primary values
    C_YELLOW='\033[1;33m'  # bold yellow — commits, resolved branches
    C_DIM='\033[0;90m'     # dim gray — secondary info
    C_RST='\033[0m'        # reset
else
    C_CYAN='' C_WHITE='' C_YELLOW='' C_DIM='' C_RST=''
fi

# =============================================================================
# Load defaults
# =============================================================================
# Reads env file which sets: CONAN_REMOTE, BUILD_IMAGE, REGISTRY, REPO_NAME,
# IMAGE, BUILD_TYPE. Any of these can be overridden by exporting before running.
source ./env

build_args=()
oci_labels=()

repo_name="${REPO_NAME:-rippled}"
repo_owner="${REPO_OWNER:-XRPLF}"
repo="${repo_owner}/${repo_name}"

# =============================================================================
# Validate ref inputs
# =============================================================================
# Exactly one of BRANCH, TAG, or GIT_HASH may be set. They are mutually
# exclusive because each implies a different lookup strategy in
# setup_worktree.sh and different metadata in the final image.
if [ -n "${GIT_HASH:-}" ] && [ -n "${BRANCH:-}" ]; then
    echo "Define either GIT_HASH or BRANCH, not both!"
    exit 1
fi
if [ -n "${TAG:-}" ] && [ -n "${GIT_HASH:-}" ]; then
    echo "Define either TAG or GIT_HASH, not both!"
    exit 1
fi
if [ -n "${TAG:-}" ] && [ -n "${BRANCH:-}" ]; then
    echo "Define either TAG or BRANCH, not both!"
    exit 1
fi

# `branch` is the value passed to setup_worktree.sh and later to the
# Dockerfile as a build arg. It starts as the TAG or BRANCH value (or
# "develop" if neither is set). If TAG is set and we can resolve the
# underlying release branch, `branch` gets overwritten with that (see
# "Validate and resolve TAG" below).
branch=${TAG:-${BRANCH:-develop}}

# ref_name is the user-facing name — the original TAG or BRANCH value before
# any resolution. Used for image tags, labels, and summary output.
# `branch` may be overwritten with the resolved release branch (e.g.,
# "release-3.1"), but ref_name stays as the original (e.g., "3.1.2").
ref_name="$branch"

# ref_type tracks whether the user specified a tag or branch. Used for:
#   - Summary output ("Tag: 3.1.2" vs "Branch: develop")
#   - Docker label key ("com.ripple.tag=3.1.2" vs "com.ripple.branch=develop")
if [ -n "${TAG:-}" ]; then
    ref_type="tag"
else
    ref_type="branch"
fi

git_hash="${GIT_HASH:-}"
mem_limit="${MEM_LIMIT:-50}"
nproc_val="${NPROC:-24}"
dry_run="${DRY_RUN:-false}"
push="${PUSH:-false}"

# Map uname architecture to Docker platform names.
arch=$(uname -m)
if [ "$arch" = "aarch64" ]; then
    build_arch="arm64"
elif [ "$arch" = "x86_64" ]; then
    build_arch="amd64"
fi

# =============================================================================
# Set up worktree
# =============================================================================
# Sources setup_worktree.sh which manages a bare repo at repos/<repo_name>.git
# with one git remote per fork owner. Creates or updates a worktree under
# worktrees/<owner>/<sanitized-branch>/.
#
# Exports:
#   WORKTREE_PATH — absolute path to the checked-out worktree
#   LATEST_HASH   — full commit SHA at the tip of the branch/tag
source ./setup_worktree.sh

git_hash="$LATEST_HASH"
# source_path is relative to $PWD so Docker COPY can reference it as a
# build context path (e.g., "worktrees/XRPLF/develop").
source_path="${WORKTREE_PATH#$PWD/}"

# =============================================================================
# Validate and resolve TAG
# =============================================================================
# When TAG is set:
#   1. Verify it exists as a real git tag (not a branch that happens to have
#      the same name). Exits with a helpful error if validation fails.
#   2. For semver tags (X.Y.Z), attempt to find the release-X.Y branch that
#      contains this commit. If found, overwrite `branch` with it so the
#      Dockerfile's fake .git plumbing (which writes to refs/heads/<branch>)
#      records the actual branch name, not the tag name.
#      Example: TAG=3.1.2 → finds release-3.1 → branch="release-3.1"
#   3. If no matching release branch is found (non-semver tag, or the branch
#      doesn't follow the release-X.Y convention), `branch` keeps the tag
#      name as a fallback.
if [ -n "${TAG:-}" ]; then
    BARE_REPO="$PWD/repos/${repo_name}.git"
    if ! git -C "$BARE_REPO" rev-parse --verify "refs/tags/${TAG}" &>/dev/null; then
        echo "Error: '${TAG}' is not a tag on ${repo_owner}. Did you mean BRANCH=${TAG}?"
        exit 1
    fi
    major_minor=$(echo "$TAG" | grep -oP '^\d+\.\d+' || true)
    if [ -n "$major_minor" ]; then
        release_branch=$(git -C "$BARE_REPO" branch -r --contains "$LATEST_HASH" 2>/dev/null \
            | sed 's/^ *//' \
            | grep "^${repo_owner}/release-${major_minor}$" \
            | sed "s|^${repo_owner}/||" || true)
        if [ -n "$release_branch" ]; then
            echo -e "Resolved tag ${C_WHITE}${TAG}${C_RST} to branch ${C_YELLOW}${release_branch}${C_RST}"
            branch="$release_branch"
        fi
    fi
fi

# =============================================================================
# Apply branch-specific patches
# =============================================================================
# Branch names are sanitized (slashes → double-dashes) to form directory names
# under branches/. E.g., "ripple/smart-escrow" → "ripple--smart-escrow".
#
# If a directory exists at branches/<owner>/<sanitized-branch>/, every .patch
# file in it is applied to the worktree via `git apply`. Patches are checked
# first with --check; already-applied or non-matching patches are skipped
# (idempotent — safe to re-run).
sanitized_branch=$(echo "$branch" | sed 's|/|--|g')
sanitized_ref=$(echo "$ref_name" | sed 's|/|--|g')

# When TAG resolves to a different branch (e.g., TAG=3.1.2 → branch=release-3.1),
# check both the original ref name and the resolved branch name for patches and
# Dockerfile overrides. The original ref name takes priority (e.g., build/XRPLF/3.1.2
# is checked before build/XRPLF/release--3.1).

# --- Patches: try ref_name first, then resolved branch ---
for candidate in "$sanitized_ref" "$sanitized_branch"; do
    patchdir="branches/${repo_owner}/${candidate}"
    if [ -d "$patchdir" ]; then
        for p in "$patchdir"/*.patch; do
            [ -f "$p" ] || continue
            if git -C "$WORKTREE_PATH" apply --check "$PWD/$p" 2>/dev/null; then
                echo "Applying patch: $p"
                git -C "$WORKTREE_PATH" apply "$PWD/$p"
            else
                echo "Patch already applied or N/A: $p"
            fi
        done
        break
    fi
done

# =============================================================================
# Resolve per-branch Dockerfile
# =============================================================================
# Checks for a custom Dockerfile in branches/<owner>/<ref>/Dockerfile on disk.
# Tries the original ref name first (e.g., branches/XRPLF/3.1.2/Dockerfile),
# then the resolved branch (e.g., branches/XRPLF/release--3.1/Dockerfile).
# Falls back to legacy build/* git branches for backward compatibility.
# dockerfile_source is set for the summary output.
for candidate in "$sanitized_ref" "$sanitized_branch"; do
    dockerfile_override="branches/${repo_owner}/${candidate}/Dockerfile"
    if [ -f "$dockerfile_override" ]; then
        echo -e "Using Dockerfile: ${C_YELLOW}${dockerfile_override}${C_RST}"
        DOCKERFILE="$dockerfile_override"
        dockerfile_source="$dockerfile_override"
        break
    fi
    # Fallback: legacy build/* branch
    build_branch="build/${repo_owner}/${candidate}"
    if git rev-parse --verify "$build_branch" &>/dev/null; then
        echo -e "Using Dockerfile from branch: ${C_YELLOW}${build_branch}${C_RST} ${C_DIM}(legacy — consider moving to ${dockerfile_override})${C_RST}"
        git show "${build_branch}:Dockerfile" > /tmp/Dockerfile.build
        DOCKERFILE="/tmp/Dockerfile.build"
        dockerfile_source="${build_branch} (git branch)"
        break
    fi
done

# =============================================================================
# Compute Docker image tag
# =============================================================================
# In CI, the tag is <commit-hash>-<arch> for uniqueness across parallel builds.
# Locally, the tag is the original ref name (sanitized: slashes → --, dashes → _).
# Uses ref_name (e.g., "3.1.2") not branch (which may have been resolved to
# "release-3.1") so the image tag matches what the user asked for.
if [ -n "${CI:-}" ]; then
    tag="${git_hash}-${build_arch}"
else
    tag="${ref_name}"
fi

# Docker tags allow [a-zA-Z0-9_.-] — only slashes need replacing.
tag=$(echo "$tag" | sed 's|/|--|g')

image="${IMAGE}:${tag}"

# =============================================================================
# Assemble docker build params
# =============================================================================
# params is the full argument list passed to `docker build`. Built up
# incrementally: context, tags, cache, dockerfile, build-args, labels,
# resource limits, and target stage.

# -- Context and primary tag --
params+=(${CONTEXT:-.})
params+=(--tag ${image})

# all_tags collects every resolved tag name so we can push them after the build.
all_tags=("${image}")

# -- Additional tags (ADD_TAGS) --
# Comma-separated list. Each entry is either:
#   - A plain suffix (no /) → expanded to ${IMAGE}:<suffix>
#   - A full image reference (contains /) → used as-is
if [ -n "${ADD_TAGS:-}" ]; then
    IFS=',' read -ra extra_tags <<< "$ADD_TAGS"
    for t in "${extra_tags[@]}"; do
        if [[ "$t" == */* ]]; then
            resolved="$t"
        else
            resolved="${IMAGE}:${t}"
        fi
        params+=(--tag "${resolved}")
        all_tags+=("${resolved}")
    done
fi

params+=(${NO_CACHE:+--no-cache})
params+=(${DOCKERFILE:+--file $DOCKERFILE})

# -- Build args --
# These are passed to the Dockerfile as ARGs. The Dockerfile uses `branch`
# and `git_hash` to create fake .git plumbing so GitInfo.cmake can embed
# the branch name and commit hash in the xrpld version string.
if [ -n "${GIT_HASH:-}" ]; then
    build_args+=("commit_id=${git_hash}")
else
    build_args+=("branch=${branch}")
fi

# Populate oci_labels[] from the template file. Keeping label definitions
# in a dedicated file makes them easy to audit at a glance — see
# labels.template for the full set and their meaning.
source ./labels.template

build_args+=("BUILD_IMAGE=${BUILD_IMAGE}")
build_args+=("CONAN_REMOTE=${CONAN_REMOTE}")
build_args+=("repo=${repo}")
build_args+=("git_hash=${git_hash}")
build_args+=("source_path=${source_path}")
build_args+=("NPROC=${nproc_val}")

for arg in "${build_args[@]}"; do
    params+=(--build-arg="${arg}")
done

# -- Labels --
# OCI standard labels (org.opencontainers.image.*) are defined in
# labels.template. ADD_LABELS entries are passed through as-is so the
# user controls the key.
for label in "${oci_labels[@]}"; do
    params+=(--label="${label}")
done
if [ -n "${ADD_LABELS:-}" ]; then
    IFS=',' read -ra extra_labels <<< "$ADD_LABELS"
    for l in "${extra_labels[@]}"; do
        params+=(--label="${l}")
    done
fi

# -- Resource limits and target --
params+=("--memory=${mem_limit}g")
params+=("--memory-swap=${mem_limit}g")
params+=("--target=${DOCKER_TARGET:-xrpld}")

# =============================================================================
# Print build summary
# =============================================================================
echo -e "${C_CYAN}Image:${C_RST}  ${C_WHITE}${image}${C_RST}"
echo -e "${C_CYAN}Source:${C_RST} ${C_WHITE}${repo_owner}/${repo_name}${C_RST}"

if [ "$ref_type" = "tag" ]; then
    echo -e "  ${C_CYAN}Tag:${C_RST}    ${C_WHITE}${TAG}${C_RST}"
    if [ "$branch" != "$ref_name" ]; then
        echo -e "  ${C_CYAN}Branch:${C_RST} ${C_WHITE}${branch}${C_RST}"
    fi
elif [ -n "${branch}" ]; then
    echo -e "  ${C_CYAN}Branch:${C_RST} ${C_WHITE}${branch}${C_RST}"
fi
echo -e "  ${C_CYAN}Commit:${C_RST} ${C_WHITE}${git_hash}${C_RST}"

if [ -n "${DOCKERFILE:-}" ]; then
    echo -e "${C_CYAN}Dockerfile:${C_RST} ${C_YELLOW}${dockerfile_source}${C_RST}"
else
    echo -e "${C_CYAN}Dockerfile:${C_RST} ${C_DIM}default${C_RST}"
fi

echo -e "${C_CYAN}Build configuration:${C_RST} ${C_WHITE}${build_type:-Release}${C_RST}"

echo -e "${C_CYAN}Tags:${C_RST}"
for t in "${all_tags[@]}"; do
    echo -e "  ${C_WHITE}${t}${C_RST}"
done

echo -e "${C_CYAN}Build args:${C_RST}"
for arg in "${build_args[@]}"; do
    echo -e "  ${C_CYAN}${arg%%=*}=${C_RST}${C_WHITE}${arg#*=}${C_RST}"
done
echo -e "${C_CYAN}Labels:${C_RST}"
for label in "${oci_labels[@]}"; do
    echo -e "  ${C_CYAN}${label%%=*}=${C_RST}${C_WHITE}${label#*=}${C_RST}"
done
if [ -n "${ADD_LABELS:-}" ]; then
    for l in "${extra_labels[@]}"; do
        echo -e "  ${C_CYAN}${l%%=*}=${C_RST}${C_WHITE}${l#*=}${C_RST}"
    done
fi

# =============================================================================
# Execute or dry-run
# =============================================================================
# PUSH=true: use --push to push all tags during the build (efficient —
# layers are pushed as they're built, and --push handles multiple --tag flags).
# Otherwise: --load to import the image locally.
if [ "${push}" = true ]; then
    params+=("--push")
else
    params+=("--load")
fi

if [ "${dry_run}" = true ]; then
    echo "DRY RUN: docker build ${params[*]}"
else
    docker build "${params[@]}"

    # -- Post-build: offer to push all tags --
    # Only prompt when PUSH wasn't set and we're in an interactive terminal.
    # Uses `docker push` per tag since the image was loaded locally, not pushed
    # during the build.
    if [ "${push}" != true ] && [ -t 0 ]; then
        echo ""
        echo "Push all tags?"
        for t in "${all_tags[@]}"; do
            echo "  ${t}"
        done
        read -r -p "[y/N] " reply
        if [[ "$reply" =~ ^[Yy]([Ee][Ss])?$ ]]; then
            for t in "${all_tags[@]}"; do
                echo "Pushing ${t}..."
                docker push "${t}"
            done
            echo "All tags pushed."
        else
            echo "Skipping push."
        fi
    fi
fi
