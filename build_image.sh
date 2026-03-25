#!/usr/bin/env bash
set +o xtrace

source ./env

build_args=()
labels=()

repo_name="${REPO_NAME:-rippled}"
repo_owner="${REPO_OWNER:-XRPLF}"
repo="${repo_owner}/${repo_name}"

if [ -n "${GIT_HASH:-}" ] && [ -n "${BRANCH:-}" ]; then
    echo "Define either GIT_HASH or BRANCH, not both!"
    exit 1
fi
branch=${BRANCH:-develop}
git_hash="${GIT_HASH:-}"
arch=$(uname -m)

if [ "$arch" = "aarch64" ]; then
    build_arch="arm64"
elif [ "$arch" = "x86_64" ]; then
    build_arch="amd64"
fi

# --- Set up worktree (replaces git clone) ---
source ./setup_worktree.sh
# setup_worktree.sh exports: WORKTREE_PATH, LATEST_HASH

git_hash="$LATEST_HASH"
source_path="${WORKTREE_PATH#$PWD/}"

# --- Resolve per-branch Dockerfile ---
sanitized_branch=$(echo "$branch" | sed 's|/|--|g')
build_branch="build/${repo_owner}/${sanitized_branch}"

if git rev-parse --verify "$build_branch" &>/dev/null; then
    echo "Using Dockerfile from branch: ${build_branch}"
    git show "${build_branch}:Dockerfile" > /tmp/Dockerfile.build
    DOCKERFILE="/tmp/Dockerfile.build"
elif [ -z "${GIT_HASH:-}" ]; then
    echo "Creating build branch: ${build_branch} (from main)"
    git branch "$build_branch" main
    echo "Using Dockerfile from main"
fi

if [ -n "${CI:-}" ]; then
    tag="${git_hash}-${build_arch}"
else
    tag="${branch}"
fi

tag=$(echo $tag | sed 's./.--.g' | sed 's.-._.g')

image="${IMAGE}:${tag}"

params+=(${CONTEXT:-.})
params+=(--tag ${image})
params+=(${NO_CACHE:+--no-cache})
params+=(${DOCKERFILE:+--file $DOCKERFILE})

if [ -n "${GIT_HASH:-}" ]; then
    build_args+=("commit_id=${git_hash}")
    tag="commit_id=${git_hash}"
else
    build_args+=("branch=${branch}")
    tag="branch=${branch}"
    labels+=("commit_id=${git_hash}")
    labels+=("repo_url=https://github.com/${repo}.git")
fi

build_args+=("repo=${repo}")
build_args+=("git_hash=${git_hash}")
build_args+=("source_path=${source_path}")

labels+=("${tag}")

# if [ -n "$CI" ]; then
#     labels="com.ripple.package_info=${CI_PROJECT_NAME}-${CI_COMMIT_REF_NAME}-${CI_COMMIT_SHA}"
# fi

build_arg="--build-arg="
build_args=( "${build_args[@]/#/ $build_arg}" )

label="--label=com.ripple."
labels=( "${labels[@]/#/ $label}" )

if (( ${#build_args[@]} )); then
    params+=(${build_args[@]})
fi

if (( ${#labels[@]} )); then
    params+=(${labels[@]})
fi

echo "Final image name: ${image}"

if [ -n "${branch}" ]; then
    echo "Branch: ${branch}"
fi
echo "Commit: ${git_hash}"
echo "Build configuration: ${build_type:-Release}"

echo "Build args:"
for arg in "${build_args[@]}"; do
    echo "${arg}"
done
echo "Labels:"
for label in "${labels[@]}"; do
    echo "${label}"
done

echo "params: ${params[@]}"
echo docker build "${params[@]}"
docker build "${params[@]}"

# if [ -n "$CI" ]; then
#     docker push $image
# fi
