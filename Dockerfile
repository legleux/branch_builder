# syntax=docker/dockerfile:1.4
ARG BUILD_IMAGE
FROM ${BUILD_IMAGE} AS build
SHELL ["/bin/bash", "-c"]
WORKDIR /root/

ARG branch
ARG git_hash
ARG source_path
ARG CONAN_REMOTE
ARG NPROC
ARG BUILD_TESTS=False
COPY ${source_path} /root/src
# Source is copied from a worktree without .git history. GitInfo.cmake runs
# git rev-parse to embed branch/hash in the xrpld version string, so we
# create a minimal .git with just enough plumbing to make rev-parse work.
RUN <<EOF
    cd /root/src && rm -f .git
    mkdir -p .git/objects .git/refs/heads/$(dirname "${branch}")
    echo "ref: refs/heads/${branch}" > .git/HEAD
    echo "${git_hash}" > .git/refs/heads/${branch}
EOF

ENV UV_TOOL_BIN_DIR=/usr/local/bin
ENV CONAN_HOME=/root/.conan2
COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /bin/

RUN <<EOF
    UPGRADE_CONAN=false
    UPGRADE_CMAKE=true
    if $UPGRADE_CONAN; then
        read -r old new < <(pip list --outdated | grep conan | awk '{print $2, $3}')
        echo "Upgrading Conan ${old} to ${new}"
        pip install conan --upgrade
    fi
    if $UPGRADE_CMAKE; then
        read -r old new < <(pip list --outdated | grep cmake | awk '{print $2, $3}')
        echo "Upgrading CMake from ${old} to ${new}"
        pip install cmake --upgrade
    fi
    conan version
EOF

# Conan config
RUN echo "core.download:parallel=$(nproc)" >> $CONAN_HOME/global.conf && \
    echo "tools.build:jobs=${NPROC}" >> $CONAN_HOME/global.conf && \
    conan remote add --index 0 xrplf "https://${CONAN_REMOTE}"

RUN conan config install src/conan/profiles/default -tf "$(conan config home)/profiles/"

# Conan install (dependency layer — cached unless conanfile/profile changes)
RUN conan install src \
    --build missing \
    --settings:all build_type=Release \
    --options:host "&:xrpld=True" \
    --options:host "&:tests=${BUILD_TESTS}" \
    --output-folder tc

# CMake configure
RUN cmake \
    -B build \
    -S src \
    -Duse_mold=ON \
    -Dtests=${BUILD_TESTS} \
    -DCMAKE_VERBOSE_MAKEFILE=OFF \
    -DCMAKE_TOOLCHAIN_FILE=/root/tc/build/generators/conan_toolchain.cmake

# CMake build + strip
RUN <<EOF
    cmake \
        --build build \
        --parallel ${NPROC}
    strip build/xrpld
EOF

FROM ubuntu:jammy AS xrpld
WORKDIR /root
# TODO: CMake --install works properly now so we don't need to do all this copying
COPY --from=build /root/build/xrpld /opt/xrpld/bin/xrpld
COPY --from=build /root/src/cfg/xrpld-example.cfg /opt/xrpld/etc/xrpld.cfg
COPY --from=build /root/src/cfg/validators-example.txt /opt/xrpld/etc/validators.txt

RUN <<EOF
ln -s /opt/xrpld/bin/xrpld /usr/bin/xrpld
ln -s /opt/xrpld/bin/xrpld /usr/local/bin/rippled
ln -s /opt/xrpld/etc /etc/opt/ripple
ln -s /opt/xrpld/ /opt/ripple
EOF

RUN mkdir -p /etc/opt && ln -s /opt/xrpld/etc/ /etc/opt/xrpld


RUN <<EOF
apt-get update && apt-get install --yes --no-install-recommends \
    ca-certificates \
    $([ "$(uname -m)" = "aarch64" ] && echo "libatomic1")
rm -rf /var/lib/apt/lists/* && apt-get clean
EOF

ENTRYPOINT ["/opt/xrpld/bin/xrpld"]

FROM busybox:glibc AS xrpld-slim
COPY --from=xrpld /etc/ssl/certs /etc/ssl/certs
COPY --from=build /root/build/xrpld /usr/bin/xrpld
COPY --from=build /root/src/cfg/xrpld-example.cfg /etc/xrpld/xrpld.cfg
COPY --from=build /root/src/cfg/validators-example.txt /etc/xrpld/validators.txt
ENTRYPOINT ["/usr/bin/xrpld"]
