"""CLI entry point: uv run branch-builder"""

from __future__ import annotations

import argparse
import sys

from builder import BuildConfig, prepare_build, run_build


def main() -> int:
    p = argparse.ArgumentParser(
        description="Build xrpld Docker images from any fork/branch",
        epilog="Env vars: REPO_OWNER, BRANCH, GIT_HASH, NPROC, MEM_LIMIT, "
               "REGISTRY, BUILD_IMAGE, CONAN_REMOTE. "
               "GitHub CI vars (GITHUB_REPOSITORY_OWNER, GITHUB_REF_NAME) "
               "are used as fallbacks.",
    )
    p.add_argument("--owner", help="Fork owner (env: REPO_OWNER, GITHUB_REPOSITORY_OWNER)")
    p.add_argument("--repo", help="Repository name")
    p.add_argument("--branch", help="Branch or tag (env: BRANCH, GITHUB_REF_NAME)")
    p.add_argument("--git-hash", help="Commit hash, mutually exclusive with --branch (env: GIT_HASH)")
    p.add_argument("--nproc", type=int, help="Build parallelism (env: NPROC)")
    p.add_argument("--mem-limit", type=int, help="Docker memory limit in GB (env: MEM_LIMIT)")
    p.add_argument("--dry-run", action="store_true")
    p.add_argument("--push", action="store_true")
    p.add_argument("--tests", action="store_true")
    p.add_argument("--slim", action="store_true", help="Use xrpld-slim target")
    p.add_argument("--no-cache", action="store_true")
    p.add_argument("--extra-tags", default="", help="Additional image:tag values (comma-separated)")
    p.add_argument("--extra-labels", default="", help="Additional key=value label pairs (comma-separated)")

    args = p.parse_args()

    # Only pass explicitly-provided args; let BuildConfig read env vars for the rest
    overrides = {}
    if args.owner is not None:
        overrides["owner"] = args.owner
    if args.repo is not None:
        overrides["repo"] = args.repo
    if args.branch is not None:
        overrides["branch"] = args.branch
    if args.git_hash is not None:
        overrides["git_hash"] = args.git_hash
    if args.nproc is not None:
        overrides["nproc"] = args.nproc
    if args.mem_limit is not None:
        overrides["mem_limit"] = args.mem_limit

    config = BuildConfig(
        **overrides,
        dry_run=args.dry_run,
        push=args.push,
        build_tests=args.tests,
        slim=args.slim,
        no_cache=args.no_cache,
        extra_tags=args.extra_tags,
        extra_labels=args.extra_labels,
    )

    result = prepare_build(config)

    print(f"Image:    {result.image_tag}")
    print(f"Worktree: {result.worktree_path}")
    print(f"Commit:   {result.commit_hash}")
    print(f"Command:  {' '.join(result.command)}")

    if config.dry_run:
        return 0

    run_build(result)
    return 0


if __name__ == "__main__":
    sys.exit(main())
