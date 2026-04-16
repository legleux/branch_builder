# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Purpose

This repo builds Docker images of `xrpld` (the XRP Ledger server, formerly `rippled`) from various feature branches across different forks. It uses git worktrees to efficiently manage branch checkouts, applies branch-specific build customizations (e.g., patching Conan recipes), and produces a multi-stage Docker image with a statically-linked binary.

## Build Command

```bash
# Configure target branch/fork in the `env` file, then:
./build_image.sh
```

Key environment variables (set in `env` or exported before running):
- `REPO_OWNER` — GitHub org/user (default: `XRPLF`)
- `REPO_NAME` — repo name (default: `rippled`)
- `BRANCH` — branch to build (default: `develop`)
- `TAG` — tag to build; validated as a real tag, resolves semver to release branch (mutually exclusive with `BRANCH` and `GIT_HASH`)
- `IMAGE` — Docker image name (constructed from `REGISTRY/REPO_NAME`)
- `GIT_HASH` — alternative to `BRANCH`; specify a commit hash (mutually exclusive with `BRANCH` and `TAG`)
- `ADD_TAGS` — comma-separated extra Docker tags (plain suffix or full `repo/name:tag`)
- `ADD_LABELS` — comma-separated extra Docker labels (`key=value`)

## Architecture

- **`build_image.sh`** — Entry point. Sources `env` and `setup_worktree.sh`, applies patches from `branches/`, resolves per-branch Dockerfiles, assembles Docker build args/labels, and runs `docker build`.
- **`setup_worktree.sh`** — Manages a single bare repo (`repos/rippled.git`) with one remote per fork owner. Creates/updates git worktrees under `worktrees/<owner>/<branch>/`. Idempotent: fetches, compares HEAD to remote, skips checkout if already up-to-date. Supports both branches and tags (annotated tags are dereferenced to commits). Exports `WORKTREE_PATH` and `LATEST_HASH`.
- **`Dockerfile`** — Two-stage build with two runtime targets:
  1. **Build stage** (`BUILD_IMAGE`, default `ghcr.io/xrplf/ci/ubuntu-jammy:gcc-12`): Installs Conan 2 + CMake via uv, runs `conan install` → `cmake configure` → `cmake --build`, strips the binary.
  2. **`xrpld` target** (`ubuntu:jammy`): Standard runtime image with the stripped `xrpld` binary + config files.
  3. **`xrpld-slim` target** (`busybox:glibc`): Minimal runtime image.
  - Source is COPYed from a worktree via `source_path` build arg. Fake `.git` plumbing is created in-container for GitInfo.cmake.
- **`env`** — Default environment variables. Uncomment the block for the desired branch/fork.
- **`branches/`** — Per-branch build customizations, organized as `branches/<owner>/<sanitized-branch>/`. Patch files (`.patch`) are applied to the worktree on the host before Docker COPY.
- **`smart_escrow/`** — Local development copy of the WAMR Conan recipe with instruction metering patches (same content as `branches/XRPLF/rippled/ripple/smart-escrow/wamr/`).

### Directory Layout (generated at runtime)

```
repos/
  rippled.git/                        # bare repo (shared object store, all remotes)
worktrees/
  XRPLF/
    develop/                          # worktree checkout
    ripple--smart-escrow/             # slashes → --
  Transia-RnD/
    feature-batch/
```

Both `repos/` and `worktrees/` are gitignored. Branch names with slashes are sanitized to double-dashes in worktree directory names (e.g., `ripple/smart-escrow` → `ripple--smart-escrow`).

## Branch-Specific Build Logic

Branch-specific customizations are applied in two ways:

1. **Patches on host** — `build_image.sh` looks for `branches/<owner>/<sanitized-branch>/*.patch` and applies them to the worktree via `git apply` before Docker COPY.
2. **Per-branch Dockerfiles** — If `branches/<owner>/<branch>/Dockerfile` exists, it is used instead of the default. Falls back to legacy `build/*` git branches.

When adding support for a new branch, add patch files, Conan recipe overrides, or a custom Dockerfile to `branches/<owner>/<branch>/`.

## Key Variables in build_image.sh

- `branch` — value passed to Dockerfile as build arg. May differ from user input (TAG=3.1.2 → branch=release-3.1).
- `ref_name` — original user input, used for image tags and labels. Never overwritten by tag resolution.
- `ref_type` — "tag" or "branch", drives summary output and label keys.
- `sanitized_branch` vs `sanitized_ref` — both checked when resolving patches and Dockerfiles.

## Gotchas

- Branch names with slashes are sanitized to `--` for directory names (e.g., `ripple/smart-escrow` → `ripple--smart-escrow`), but `release-3.1` has a real dash, NOT a sanitized slash — its directory is `release-3.1` not `release--3.1`.
- The default Dockerfile uses `xrpld` (the renamed binary). Older releases (3.1.x) use `rippled` — they need a custom Dockerfile in `branches/XRPLF/release-3.1/`.
- The Dockerfile creates fake `.git` plumbing for GitInfo.cmake. The `$(dirname "${branch}")` in the mkdir handles nested branch names like `release-3.1`.
- `conan config install src/conan/profiles/default` must be in the Dockerfile or Conan uses the base image's default profile (which may have wrong cppstd).

## TODO

- GitHub Actions workflow for automated image builds (CI counterpart to the local build_image.sh / TUI flow)

## WAMR Instruction Metering Patch

The `ripp_metering.patch` adds a `WAMR_BUILD_INSTRUCTION_METERING` CMake flag to WAMR (WebAssembly Micro Runtime) that enables per-instruction execution limits. The Conan recipe (`conanfile.py`) pins WAMR at commit `c883fafe` and enables the fast interpreter with metering.
