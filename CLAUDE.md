# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Purpose

This repo builds Docker images of `rippled` (the XRP Ledger server) from various feature branches across different forks. It uses git worktrees to efficiently manage branch checkouts, applies branch-specific build customizations (e.g., patching Conan recipes), and produces a multi-stage Docker image with a statically-linked `rippled` binary.

## Build Command

```bash
# Configure target branch/fork in the `env` file, then:
./build_image.sh
```

Key environment variables (set in `env` or exported before running):
- `REPO_OWNER` — GitHub org/user (default: `XRPLF`)
- `REPO_NAME` — repo name (default: `rippled`)
- `BRANCH` — branch to build (default: `develop`)
- `IMAGE` — Docker image name (constructed from `REGISTRY/REPO_NAME`)
- `GIT_HASH` — alternative to `BRANCH`; specify a commit hash (mutually exclusive with `BRANCH`)

## Architecture

- **`build_image.sh`** — Entry point. Sources `env` and `setup_worktree.sh`, assembles Docker build args/labels, and runs `docker build`.
- **`setup_worktree.sh`** — Manages a single bare repo (`repos/rippled.git`) with one remote per fork owner. Creates/updates git worktrees under `worktrees/<owner>/<branch>/`. Idempotent: fetches, compares HEAD to remote, skips checkout if already up-to-date. Exports `WORKTREE_PATH` and `LATEST_HASH`.
- **`Dockerfile`** — Two-stage build:
  1. **Build stage** (`gcc:11`): Installs Conan 2 + CMake, applies branch-specific recipe overrides from `branches/`, runs `conan build` on `rippled`.
  2. **Runtime stage** (`debian:bullseye-slim`): Copies the stripped `rippled` binary + config files.
  - Uses `source_path` build arg to locate the worktree checkout.
- **`env`** — Default environment variables. Uncomment the block for the desired branch/fork.
- **`branches/`** — Per-branch build customizations, organized as `branches/<owner>/<repo>/<branch>/`. These files are bind-mounted into the Docker build and used to override or supplement the upstream source (e.g., replacing Conan recipes).
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

The Dockerfile contains conditional logic for specific branches (around line 92):
- `master`/`release` — standard build
- `feature-batch` — patches protobuf version in conanfile
- `ripple/smart-escrow` — replaces the WAMR Conan recipe with a custom version that adds instruction metering support

When adding support for a new branch, add its customizations to both `branches/<owner>/<repo>/<branch>/` and the Dockerfile's branch-conditional block.

## WAMR Instruction Metering Patch

The `ripp_metering.patch` adds a `WAMR_BUILD_INSTRUCTION_METERING` CMake flag to WAMR (WebAssembly Micro Runtime) that enables per-instruction execution limits. The Conan recipe (`conanfile.py`) pins WAMR at commit `c883fafe` and enables the fast interpreter with metering.
