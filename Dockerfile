FROM gcc:11 AS build
SHELL ["/bin/bash", "-c"]

ARG branch=develop
ARG owner=XRPLF
ARG repo_name=rippled
ARG repo=${owner}/${repo_name}
ARG compiler=gcc
ARG build_type=Release
ARG conan_remote="ripple-stage http://18.143.149.228:8081/artifactory/api/conan/stage"

ARG conan_version=2.16.1
ARG cmake_version=4.0.0

ENV CONAN_HOME="/root/conan2"
# Maybe prefer uv?
# ENV UV_TOOL_BIN_DIR=/usr/local/bin
# COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /bin/

RUN <<EOF
    pkgs=(python3-pip python-is-python3) # pip and python for Conan and CMake
    pkgs+=(ca-certificates) # Warning in logs about SSL if not installed
    ## dev stuff
    pkgs+=(jq) # For pretty printing info from container
    pkgs+=(vim) # For ... vim

    apt-get update && apt-get install --yes "${pkgs[@]}"
    # uv tool install --python 3.13 conan
    # uv tool install --python 3.13 "cmake<4"
    pip_packages=()
    pip_packages+=("cmake==${cmake_version}")
    pip_packages+=("conan==${conan_version}")
    pip install --no-cache-dir "${pip_packages[@]}"
EOF

COPY <<EOF /root/conan2/profiles/default

    [settings]
        os={{ detect_api.detect_os() }}
        arch={{ detect_api.detect_arch() }}
    {% if not os.getenv("COMPILER")%}
    {% set compiler, version, compiler_exe = detect_api.detect_default_compiler() %}
        compiler={{ compiler }}
        compiler.version={{ detect_api.default_compiler_version(compiler, version) }}
        compiler.libcxx={{ detect_api.detect_libcxx(compiler, version, compiler_exe) }}
        compiler.cppstd=20
    {% endif %}

        build_type=Release

    [options]
    {% if os.getenv("CLIO")  %}
        xrpl/*:xrpld=False
        xrpl/*:tests=False
        xrpl/*:rocksdb=False
        &:tests=False
    {% else %}
        &:xrpld=True
        &:rocksdb=False
    {% endif %}

    [conf]
        tools.build:jobs=22

    [tool_requires]
        !cmake/*: cmake/[>=3 <4]
EOF

COPY smart_escrow/wamr wamr

RUN <<EOF
    set -ex
#     repo="${repo:-XRPLF/rippled}"
# #     branch=${branch:-develop}
#     branch=${branch:-conan2}
    # source_dir=${source_dir:-rippled}
    build_dir=${build_dir:-build}
    config=${build_config:-Release}

    num_proc=$(($(nproc) - 2))
    if [ "$num_proc" -lt 3 ]; then
        echo "Building with 1 processor."
        num_proc=1
    fi

    git clone --branch "${branch}" --depth 1 "https://github.com/${repo}.git"

    ### Conan config stuff
    echo "core.download:parallel = $(nproc)" >> $CONAN_HOME/global.conf
    echo "tools.build:jobs = $(nproc)" >>  $CONAN_HOME/global.conf

    conan remote add --index 0 ${conan_remote}

    ### Branch specific configs
    if [[ "${branch}" =~ ^(master|release)$ ]]; then
        config=Release # get the commit id in the version string

    elif [[ "${branch}" = "feature-batch" ]]; then
        cd ${repo_name} && sed -i s#protobuf/3.21.9#protobuf/3.21.12# conanfile.py && cd -

    elif [[ "${branch}" = "ripple/smart-escrow" ]]; then
        wamr_recipe="${repo_name}/external/wamr"
        rm -rf "${wamr_recipe}"
        mv wamr "${wamr_recipe}"
        conan export --version 2.2.0 "${wamr_recipe}"
    fi

    conan build "${repo_name}" -of "${build_dir}" --build missing

    strip /build/build/Release/rippled
EOF




FROM debian:bullseye-slim AS rippled

RUN  apt-get update && apt-get install -y tree vim ca-certificates jq curl && rm -rf /var/lib/apt/lists/*
COPY --from=build /build/build/Release/rippled /opt/ripple/bin/rippled
COPY --from=build /rippled/cfg/rippled-example.cfg /opt/ripple/etc/rippled.cfg
COPY --from=build /rippled/cfg/validators-example.txt /opt/ripple/etc/validtors.txt

RUN ln -s /opt/ripple/bin/rippled /usr/local/bin/rippled
RUN mkdir -p /etc/opt && ln -s /opt/ripple/etc/ /etc/opt/ripple

RUN if [ $(uname -m) = "aarch64" ];then apt-get update && apt-get install --yes libatomic1 && apt-get clean && rm -rf /var/cache/apt/lists; fi

ENTRYPOINT ["/opt/ripple/bin/rippled"]
