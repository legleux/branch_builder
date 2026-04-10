# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Purpose

This repo builds Docker images of `rippled` (the XRP Ledger server) from various feature branches across different forks. It uses git worktrees to efficiently manage branch checkouts, applies branch-specific build customizations (e.g., patching Conan recipes), and produces a multi-stage Docker image with a statically-linked `rippled` binary.

## Build Command

```bash
# CLI (uses env vars for defaults, CLI flags to override):
uv run branch-builder --owner XRPLF --branch develop --dry-run

# Or set env vars and run with no flags:
REPO_OWNER=XRPLF BRANCH=develop uv run branch-builder

# TUI (interactive):
uv run python -m tui

# Legacy shell script (still present, but builder/ module is canonical):
# ./build_image.sh
```

Key environment variables (CLI flags override these):
- `REPO_OWNER` / `GITHUB_REPOSITORY_OWNER` — GitHub org/user (default: `XRPLF`)
- `BRANCH` / `GITHUB_REF_NAME` — branch to build (default: `develop`)
- `GIT_HASH` — commit hash, mutually exclusive with BRANCH (opt-in only; GITHUB_SHA is NOT auto-used)
- `REGISTRY` — Docker registry (default: `legleux`)
- `BUILD_IMAGE` — CI base image (default: `ghcr.io/xrplf/ci/ubuntu-jammy:gcc-12`)
- `CONAN_REMOTE` — Conan remote URL (default: `conan.ripplex.io`)
- `NPROC` — build parallelism (default: `24`)
- `MEM_LIMIT` — Docker memory limit in GB (default: `50`)

## Tests

```bash
uv run pytest tests/ -v
```

## Architecture

- **`builder/`** — Python package that replaces `build_image.sh` + `setup_worktree.sh`. Public API: `BuildConfig` (dataclass), `prepare_build()` (worktree + patches + docker command), `run_build()` (execute). CLI via `uv run branch-builder`. The TUI imports this module directly.
  - **`builder/worktree.py`** — Manages a single bare repo (`repos/rippled.git`) with one remote per fork owner. Creates/updates git worktrees under `worktrees/<owner>/<branch>/`. Idempotent. Supports branches, tags (annotated tags are dereferenced to commits), and raw commit hashes.
  - **`builder/__init__.py`** — `BuildConfig`, `prepare_build()`, `run_build()`. Env var fallbacks for CI (GITHUB_REPOSITORY_OWNER, GITHUB_REF_NAME).
  - **`builder/__main__.py`** — CLI entry point (`[project.scripts]` → `branch-builder`).
- **`build_image.sh`** — Legacy shell entry point (still present). Sources `env` and `setup_worktree.sh`.
- **`setup_worktree.sh`** — Legacy shell worktree management (still present).
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
2. **Per-branch Dockerfiles** — If a git branch named `build/<owner>/<sanitized-branch>` exists in this repo, its `Dockerfile` is used instead of the default.

When adding support for a new branch, add patch files or Conan recipe overrides to `branches/<owner>/<sanitized-branch>/`.

## WAMR Instruction Metering Patch

The `ripp_metering.patch` adds a `WAMR_BUILD_INSTRUCTION_METERING` CMake flag to WAMR (WebAssembly Micro Runtime) that enables per-instruction execution limits. The Conan recipe (`conanfile.py`) pins WAMR at commit `c883fafe` and enables the fast interpreter with metering.
