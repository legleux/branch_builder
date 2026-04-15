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

Most branches build with the default Dockerfile and no patches. Just set the environment variables and build:

```bash
REPO_OWNER=Transia-RnD BRANCH=feature-batch ./build_image.sh
```

When a branch won't build with the defaults, you have two mechanisms: **host-side patches** and **per-branch Dockerfiles**. Use patches for small fixes; use a custom Dockerfile when the build process itself needs to change.

### Host-Side Patches

Patches are applied to the worktree _before_ Docker copies the source. This is the right tool for small source fixes that don't change the build process (fixing case-sensitivity issues, tweaking CMake flags, etc.).

1. Figure out the patch directory name. Branch slashes become double-dashes:

   | Owner | Branch | Patch directory |
   |---|---|---|
   | `XRPLF` | `develop` | `branches/XRPLF/develop/` |
   | `XRPLF` | `ripple/smart-escrow` | `branches/XRPLF/ripple--smart-escrow/` |
   | `tequdev` | `sponsor` | `branches/tequdev/sponsor/` |

2. Create the directory and add `.patch` files:

   ```bash
   mkdir -p branches/tequdev/sponsor
   # Generate a patch from the worktree, or write one by hand
   cp fix-case-sensitivity.patch branches/tequdev/sponsor/
   ```

3. Build. `build_image.sh` applies every `.patch` file in that directory via `git apply`. Patches that are already applied (or don't match) are skipped.

**Real example** — the `tequdev/sponsor` branch has a case-sensitivity issue on Linux:

```
branches/tequdev/sponsor/fix-case-sensitivity.patch
```

This renames `Sponsor/` to `sponsor/` in the include paths so the build succeeds on case-sensitive filesystems.

### Conan Recipe Overrides

Some branches need a patched Conan recipe — for example, the `ripple/smart-escrow` branch builds WAMR with instruction metering enabled. To set this up:

1. Put the custom `conanfile.py` (and any patch files it references via `conandata.yml`) in the branch's patch directory:

   ```
   branches/XRPLF/ripple--smart-escrow/wamr/
     conanfile.py          # custom Conan recipe
     patches/
       ripp_metering.patch # applied by Conan during build
   ```

2. The per-branch Dockerfile (or a host-side patch) must configure Conan to use this local recipe instead of fetching from the remote. See the `build/XRPLF/3.1.2` branch for an example of how this is wired up in a custom Dockerfile.

### Per-Branch Dockerfiles

When patches aren't enough — the branch needs different Conan options, an extra build step, or a different base image — use a per-branch Dockerfile.

1. Create a git branch in **this repo** (not the rippled repo) named `build/<owner>/<sanitized-branch>`:

   ```bash
   git checkout -b build/tequdev/sponsor
   ```

2. Edit the `Dockerfile` at the repo root on that branch. It receives the same build args as the default Dockerfile:

   | Build arg | Value |
   |---|---|
   | `branch` | Branch name (e.g., `sponsor`) |
   | `git_hash` | Resolved commit hash |
   | `source_path` | Relative path to the worktree (e.g., `worktrees/tequdev/sponsor`) |
   | `CONAN_REMOTE` | Conan remote URL |
   | `NPROC` | Parallel job count |
   | `BUILD_IMAGE` | Base build image |
   | `BUILD_TESTS` | `True` or `False` |

3. Commit and switch back to your working branch:

   ```bash
   git add Dockerfile
   git commit -m "custom Dockerfile for tequdev/sponsor"
   git checkout -
   ```

4. Build normally. `build_image.sh` detects the `build/` branch automatically:

   ```bash
   REPO_OWNER=tequdev BRANCH=sponsor ./build_image.sh
   ```

   You'll see `Using Dockerfile from branch: build/tequdev/sponsor` in the output.

**Existing example**: `build/XRPLF/3.1.2` has a custom Dockerfile for the 3.1.2 release.

### Testing Before a Full Build

Full builds take a long time. To iterate on patches or Dockerfile changes, use a throwaway container with the worktree mounted:

```bash
# First, set up the worktree without building
source ./env
REPO_OWNER=tequdev BRANCH=sponsor source ./setup_worktree.sh

# Drop into the build image with the source mounted
docker run --rm -it \
  -v "$WORKTREE_PATH:/root/src" \
  ghcr.io/xrplf/ci/ubuntu-jammy:gcc-12 \
  bash

# Inside the container, test conan install / cmake configure
conan install /root/src --build missing --output-folder tc
cmake -B build -S /root/src -DCMAKE_TOOLCHAIN_FILE=tc/build/generators/conan_toolchain.cmake
```

## Maintaining Existing Branches

### Updating a Worktree

Worktrees are updated automatically on each build. If the remote branch has new commits, `setup_worktree.sh` fetches and checks out the latest. If the worktree is already at HEAD, it skips the checkout.

### Re-generating Patches

If upstream changes break an existing patch:

1. Build — `git apply` will report the patch failed (the build continues, printing `Patch already applied or N/A`).
2. Fix the patch against the new source. The easiest way:

   ```bash
   cd worktrees/<owner>/<sanitized-branch>
   # Make the fix manually
   git diff > ../../../branches/<owner>/<sanitized-branch>/my-fix.patch
   ```

3. Replace the old `.patch` file and rebuild.

### Cleaning Up Stale Worktrees

Worktrees and the bare repo accumulate over time. To reclaim disk space:

```bash
# List all worktrees
git -C repos/rippled.git worktree list

# Remove a specific worktree
git -C repos/rippled.git worktree remove worktrees/tequdev/sponsor

# Prune stale worktree references
git -C repos/rippled.git worktree prune

# Nuclear option — remove everything and rebuild from scratch
rm -rf repos/ worktrees/
```

### Removing Branch Support

1. Delete the patch directory: `rm -rf branches/<owner>/<sanitized-branch>/`
2. Delete the build branch (if one exists): `git branch -D build/<owner>/<sanitized-branch>`
3. Optionally remove the worktree (see above).

## Troubleshooting

| Problem | Cause | Fix |
|---|---|---|
| `Patch already applied or N/A` for a patch that should apply | Upstream incorporated the fix, or the patch context drifted | Re-generate the patch against current source, or delete it |
| `'branch' not found as branch or tag on <remote>` | Branch was deleted upstream, or typo in `BRANCH` | Check the remote: `git -C repos/rippled.git ls-remote <owner>` |
| Conan install fails with missing recipe | Branch needs a custom Conan recipe not on the remote | Add the recipe to `branches/<owner>/<sanitized-branch>/` and wire it into a per-branch Dockerfile |
| Build OOM-killed | `MEM_LIMIT` too low for the link step | Increase `MEM_LIMIT` (default 50 GB) or reduce `NPROC` |
| Docker cache stale after switching branches | Docker layer cache from a previous branch's source | Rebuild with `NO_CACHE=1 ./build_image.sh` |

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
