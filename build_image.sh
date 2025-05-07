#!/usr/bin/env bash
set -o xtrace

registry="legleux"

## Batch Transactions
# repo_owner="Transia-RnD"
# export branch="feature-batch"

## Account Permission
# repo_owner="yinyiqian1"
# export branch="account_permission_new"

## Smart escrow
repo_owner="XRPLF"
export branch="ripple/smart-escrow"

repo_name="rippled"

repo="${repo_owner}/${repo_name}"
git_hash=$(git ls-remote https://github.com/${repo}.git ${branch} | awk '{ print $1}')
build_type="Release"

export IMAGE="${registry}/${repo_name}"

arch=$(uname -m)

if [ "$arch" = "aarch64" ]; then
    build_arch="arm64"
elif [ "$arch" = "x86_64" ]; then
    build_arch="amd64"
fi

if [ -n "${CI}" ]; then
    tag="${git_hash}-${build_arch}"
else
    tag="${branch}"
fi

tag=$(echo $tag | sed 's./.--.g' | sed 's.-._.g')

image="${IMAGE}:${tag}"
additional_labels=""

if [ -n "$CI" ]; then
    additional_labels="--label com.ripple.package_info=${CI_PROJECT_NAME}-${CI_COMMIT_REF_NAME}-${CI_COMMIT_SHA}"
fi

# loop over labels to build up "--label" commands
# loop over build-args to build up "--build-arg" commands

export BUILDKIT_PROGRESS=plain
# docker build . --no-cache  \
    # --build-arg owner="${owner}" \

echo "IMAGE: ${IMAGE}"
echo "Branch: ${branch}"
echo "Git commit: ${git_hash}"
echo "Build configuration: ${build_type}"
echo "Finale imag name: ${image}"

docker build . \
    --tag "${image}" \
    --build-arg branch="${branch}" \
    --build-arg repo="${repo}" \
    --build-arg build_type="${build_type}" \
    --label "com.ripple.commit_id=${git_hash}" \
    --label "com.ripple.branch=${branch}" \
    $additional_labels

# if [ -n "$CI" ]; then
#     docker push $image
# fi
