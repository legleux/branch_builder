# Branch Builder

Build Docker images of [xrpld](https://github.com/XRPLF/rippled) (the XRP Ledger server) from any fork, branch, or commit hash. Uses git worktrees for efficient source management and supports branch-specific build customizations like patched Conan recipes.

## Prerequisites

- Docker (with BuildKit)
- `gh` CLI (authenticated, for the TUI)
- Python 3.14+ and [uv](https://docs.astral.sh/uv/) (for the TUI)

## Quick Start

### CLI

Set your target in environment variables and run:

```bash
# Build XRPLF/rippled develop (defaults)
./build_image.sh

# Build a specific fork/branch
REPO_OWNER=tequdev BRANCH=sponsor ./build_image.sh

# Build a specific commit
REPO_OWNER=XRPLF GIT_HASH=abc123def456 ./build_image.sh

# Dry run (print the docker command without executing)
DRY_RUN=true ./build_image.sh

# Build and push to registry
PUSH=true ./build_image.sh
```

### TUI

An interactive terminal UI for browsing PRs, branches, and forks, then launching builds:

```bash
uv run python -m tui
```

## Environment Variables

Set these in the `env` file or export before running `build_image.sh`:

| Variable | Default | Description |
|---|---|---|
| `REPO_OWNER` | `XRPLF` | GitHub org or user |
| `REPO_NAME` | `rippled` | Repository name |
| `BRANCH` | `develop` | Branch to build (mutually exclusive with `GIT_HASH`) |
| `GIT_HASH` | | Commit hash to build (mutually exclusive with `BRANCH`) |
| `IMAGE` | `${REGISTRY}/${REPO_NAME}` | Docker image name |
| `REGISTRY` | `legleux` | Docker registry |
| `BUILD_IMAGE` | `ghcr.io/xrplf/ci/ubuntu-jammy:gcc-12` | Base image for the build stage |
| `CONAN_REMOTE` | `conan.ripplex.io` | Conan package remote |
| `NPROC` | `24` | Parallel build jobs |
| `MEM_LIMIT` | `50` | Docker build memory limit in GB |
| `DRY_RUN` | `false` | Print build command without executing |
| `PUSH` | `false` | Push image to registry (`false` loads locally) |
| `DOCKER_TARGET` | `xrpld` | Dockerfile target stage (`xrpld` or `xrpld-slim`) |
| `BUILD_TESTS` | `False` | Build xrpld unit tests |
| `NO_CACHE` | | Set to any value to disable Docker layer cache |

## How It Works

### 1. Worktree Setup

`setup_worktree.sh` maintains a single bare repo at `repos/rippled.git` with one git remote per fork owner. When you build, it:

1. Adds the fork as a remote if needed
2. Fetches the target branch or commit
3. Creates (or updates) a worktree under `worktrees/<owner>/<branch>/`
4. Skips checkout if the worktree is already at the latest commit

Branch names with slashes are sanitized to double-dashes in directory names (e.g., `ripple/smart-escrow` becomes `ripple--smart-escrow`).

### 2. Patch Application

If a directory exists at `branches/<owner>/<sanitized-branch>/`, any `.patch` files in it are applied to the worktree before the Docker build. Patches that are already applied are skipped.

### 3. Per-Branch Dockerfiles

If a git branch named `build/<owner>/<sanitized-branch>` exists in this repo, its `Dockerfile` is extracted and used instead of the default.

### 4. Docker Build

The Dockerfile runs a two-stage build:

- **Build stage** (on `BUILD_IMAGE`): installs Conan 2 + CMake via uv, runs `conan install` then `cmake --build`, and strips the binary.
- **Runtime stage**: copies just the `xrpld` binary and config files.

Two runtime targets are available:

| Target | Base Image | Use Case |
|---|---|---|
| `xrpld` | `ubuntu:jammy` | Standard image with shell and package manager |
| `xrpld-slim` | `busybox:glibc` | Minimal image (~5x smaller) |

## TUI Features

The TUI (`uv run python -m tui`) provides three tabs for selecting what to build:

- **PRs** -- browse open pull requests on XRPLF/rippled with filtering by number, title, author, or branch name. External contributors are highlighted in orange.
- **Branches** -- browse branches of the base repo, grouped by path prefix (e.g., all `ripple/*` branches are collapsible).
- **Forks** -- browse forks of XRPLF/rippled. Expand a fork to lazy-load its branches.

After selecting a target, the **Options** screen lets you configure:

- NPROC and memory limit
- Push to registry / dry run / build tests / slim image
- Additional tags and labels

The **Build** screen streams the build log in real time and, on success, shows the image size, tags, and a collapsible `docker inspect` tree.

## Adding a New Branch

1. If the branch needs patches or custom Conan recipes, add them to `branches/<owner>/<sanitized-branch>/`.
2. If it needs a completely different Dockerfile, create a git branch named `build/<owner>/<sanitized-branch>` with the custom `Dockerfile` at its root.
3. Build it: `REPO_OWNER=<owner> BRANCH=<branch> ./build_image.sh`

## Directory Layout

Generated at runtime (gitignored):

```
repos/
  rippled.git/              # bare repo, shared object store for all remotes
worktrees/
  XRPLF/
    develop/                # worktree checkout
    ripple--smart-escrow/
  tequdev/
    sponsor/
```

## Project Structure

```
build_image.sh              # main entry point
setup_worktree.sh           # git worktree management
Dockerfile                  # two-stage xrpld build
env                         # default environment variables
branches/                   # per-branch build customizations (patches, recipes)
tui/                        # Textual TUI app
  app.py                    #   app shell + gh auth check
  github.py                 #   GitHub API queries (forks, branches, PRs)
  screens/
    select.py               #   PR/branch/fork browser
    options.py              #   build configuration form
    build.py                #   live build log + image inspect
smart_escrow/               # local dev copy of WAMR Conan recipe with metering
```
