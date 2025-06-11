#!/usr/bin/env bash
set -o xtrace

source ./env

build_args=()
labels=()

repo_name="${REPO_NAME:-rippled}"
repo_owner="${REPO_OWNER:-XRPLF}"
repo="${repo_owner}/${repo_name}"

# if [ -n "${GIT_HASH}" ] && [ -n "${BRANCH}" ]; then
#     echo "Define either GIT_HASH or BRANCH, not both!"
#     exit 1
# # elif [ -z "${GIT_HASH}" ] && [ -z "${BRANCH}" ]; then
# #     BRANCH="develop"
# fi
branch=${BRANCH:-develop}
# arch=$(uname -m)

# if [ "$arch" = "aarch64" ]; then
#     build_arch="arm64"
# elif [ "$arch" = "x86_64" ]; then
#     build_arch="amd64"
# fi

if [ -n "${CI}" ]; then
    tag="${git_hash}-${build_arch}"
else
    tag="${branch}"
fi

tag=$(echo $tag | sed 's./.--.g' | sed 's.-._.g')

image="${IMAGE}:${tag}"

params+=(${NO_CACHE:+--no-cache})
params+=(${DOCKERFILE:+--file $DOCKERFILE})

repo_path="./repos/${repo}/${branch}"

if [ -n "${git_hash}" ]; then
    mkdir ${repo_path} && cd ${repo_path}
    git init
    git remote add origin "${repo}"
    git fetch origin "${git_hash}"
    git reset --hard FETCH_HEAD
    cd -
    build_args+=("commit_id=${git_hash}")
    tag="commit_id=${git_hash}"
elif [ -n "${branch}" ]; then
    repo_url="https://github.com/${repo}.git"
    build_args+=("branch=${branch}")
    tag="branch=${branch}"
    # echo "Cloning ${repo_url}@${branch}"
    # git clone --depth 1 --branch "${branch}" "${repo_url}" "${repo_path}" &> /dev/null
    git_hash=$(git -C "${repo_path}" rev-parse HEAD)
    labels+=("commit_id=${git_hash}")
    labels+=("repo_url=${repo_url}")
fi

build_args+=("repo=${repo_path}")
build_args+=("git_hash=${git_hash}")

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


if [ -n "${branch}" ]; then
    echo "Branch: ${branch}"
fi
echo "Commit: ${git_hash}"
echo "Build configuration: ${build_type}"

echo "Build args:"
for arg in "${build_args[@]}"; do
    echo "${arg}"
done
echo "Labels:"
for label in "${labels[@]}"; do
    echo "${label}"
done

# echo "Command:"
# echo 'docker build . \'
# for p in "${docker_params[@]}"; do
#     echo -e "\t${p} \\"
# done
echo "params: ${params[@]}"
echo docker build "${params[@]}"
# params+=(${CONTEXT:-.})
# echo "Using context: ${context}"
echo "Final image name: ${image}"
docker build . --tag "${image}" "${params[@]}"
# BUILDKIT_PROGRESS=plain docker build . \
#     --tag "${image}" \
#     --build-arg branch="${branch}" \
#     --build-arg repo="${repo}" \
#     --build-arg build_type="${build_type}" \
#     --label "com.ripple.commit_id=${git_hash}" \
#     --label "com.ripple.branch=${branch}" \
#     $additional_labels

# if [ -n "$CI" ]; then
#     docker push $image
# fi
