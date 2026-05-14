# Design: `--help` / `-h` flag for `build_image.sh`

**Date:** 2026-05-13

## Summary

Add `--help` / `-h` support to `build_image.sh` so users can discover the script's interface without reading the README or the source.

## Approach

Simple `$1` check at the top of the script (Approach A). The script takes no other positional arguments — all inputs are environment variables — so a full option parser adds no value.

## Placement

After the color variable setup (line 41), before `source ./env` (line 48). This ensures `--help` works even if `env` is missing or malformed.

```bash
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    # print help
    exit 0
fi
```

## Help Content

Verbosity: **medium** — usage line, examples, environment variable reference grouped by concern, README pointer.

Colors use the existing color variables (`C_CYAN`, `C_WHITE`, `C_DIM`, `C_RST`) already set before the check.

### Usage line

```
Usage: [VAR=value ...] ./build_image.sh [--help]
```

### Examples

```
./build_image.sh                                           # develop (defaults)
REPO_OWNER=tequdev BRANCH=sponsor ./build_image.sh        # fork/branch
GIT_HASH=abc123 ./build_image.sh                          # commit hash
TAG=3.1.2 ./build_image.sh                                # release tag
DRY_RUN=true ./build_image.sh                             # print command only
LOCAL_REPO=~/dev/rippled BRANCH=my-feature ./build_image.sh
LOCAL_REPO=~/dev/rippled LOCAL_DIRTY=1 ./build_image.sh
ADD_TAGS=latest,staging ./build_image.sh                  # extra tag suffixes
ADD_TAGS=other/repo:v1 ./build_image.sh                   # full image ref tag
ADD_LABELS=env=staging,team=infra ./build_image.sh        # extra OCI labels
PUSH=true ADD_TAGS=latest ADD_LABELS=env=prod ./build_image.sh
```

### Environment variable groups

**Source**

| Variable | Default | Description |
|---|---|---|
| `REPO_OWNER` | `XRPLF` | GitHub org or user |
| `REPO_NAME` | `rippled` | Repository name |
| `BRANCH` | `develop` | Branch to build (mutually exclusive with `TAG`, `GIT_HASH`) |
| `TAG` | | Tag to build; validated as a real tag |
| `GIT_HASH` | | Commit hash to build |
| `LOCAL_REPO` | | Path to a local rippled clone |
| `LOCAL_DIRTY` | | With `LOCAL_REPO`: build current working tree |

**Image**

| Variable | Default | Description |
|---|---|---|
| `IMAGE` | `legleux/rippled` | Docker image name |
| `REGISTRY` | `legleux` | Docker registry |
| `ADD_TAGS` | | Comma-separated extra tags |
| `ADD_LABELS` | | Comma-separated extra labels (`key=value`) |

**Build**

| Variable | Default | Description |
|---|---|---|
| `BUILD_IMAGE` | `ghcr.io/xrplf/ci/ubuntu-jammy:gcc-12` | Build stage base image |
| `CONAN_REMOTE` | `conan.ripplex.io` | Conan package remote |
| `NPROC` | `16` | Parallel build jobs |
| `MEM_LIMIT` | `50` | Memory limit in GB |
| `DOCKER_TARGET` | `xrpld` | Target stage (`xrpld` or `xrpld-slim`) |
| `BUILD_TESTS` | `False` | Build unit tests |
| `NO_CACHE` | | Set to disable Docker layer cache |

**Run**

| Variable | Default | Description |
|---|---|---|
| `DRY_RUN` | `false` | Print docker command without executing |
| `PUSH` | `false` | Push image to registry |

### Footer

```
See README.md for full documentation.
```

## Implementation

One block of bash added to `build_image.sh` after line 41:

```bash
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    echo -e "${C_WHITE}Usage:${C_RST} [VAR=value ...] ./build_image.sh [--help]"
    echo ""
    echo -e "${C_CYAN}Examples:${C_RST}"
    # ... echo lines for each example ...
    echo ""
    echo -e "${C_CYAN}Source:${C_RST}"
    # ... variable lines ...
    echo ""
    echo -e "${C_DIM}See README.md for full documentation.${C_RST}"
    exit 0
fi
```

No other files need to change.
