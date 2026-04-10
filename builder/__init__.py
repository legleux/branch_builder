"""Branch Builder — build xrpld Docker images from any fork/branch.

Public API:
    config = BuildConfig(owner="XRPLF", branch="develop")
    result = prepare_build(config)   # worktree + patches + docker command
    run_build(result)                # execute docker build
"""

from __future__ import annotations

import os
import platform
import subprocess
from dataclasses import dataclass, field
from pathlib import Path

from builder.worktree import setup_worktree


def _env(*keys: str, default: str = "") -> str:
    """Return first non-empty env var from keys, or default."""
    for k in keys:
        val = os.environ.get(k)
        if val:
            return val
    return default


@dataclass
class BuildConfig:
    """Build configuration.

    CLI parameters override env vars. Env vars provide defaults so CI
    workflows can rely on GITHUB_* or custom vars without passing flags.

    Env var lookup order (first non-empty wins):
        owner:      REPO_OWNER → GITHUB_REPOSITORY_OWNER → "XRPLF"
        branch:     BRANCH → GITHUB_REF_NAME → "develop"
        git_hash:   GIT_HASH → None  (opt-in; GITHUB_SHA is NOT auto-used)
        nproc:      NPROC → 24
        mem_limit:  MEM_LIMIT → 50
        registry:   REGISTRY → "legleux"
        build_image: BUILD_IMAGE → CI base image
        conan_remote: CONAN_REMOTE → "conan.ripplex.io"
    """

    # Git / ref selection — env vars let CI workflows skip CLI params
    owner: str = field(
        default_factory=lambda: _env("REPO_OWNER", "GITHUB_REPOSITORY_OWNER", default="XRPLF")
    )
    repo: str = "rippled"
    branch: str = field(
        default_factory=lambda: _env("BRANCH", "GITHUB_REF_NAME", default="develop")
    )
    git_hash: str | None = field(
        default_factory=lambda: _env("GIT_HASH") or None
    )

    # Build resources
    nproc: int = field(
        default_factory=lambda: int(_env("NPROC", default="24"))
    )
    mem_limit: int = field(
        default_factory=lambda: int(_env("MEM_LIMIT", default="50"))
    )

    # Flags
    dry_run: bool = False
    push: bool = False
    build_tests: bool = False
    slim: bool = False
    no_cache: bool = False

    # Extra docker tags (full image:tag values, comma-separated)
    extra_tags: str = ""
    # Extra docker labels (key=value pairs, comma-separated)
    extra_labels: str = ""

    # Infra defaults from env (tokens, registry, CI context)
    registry: str = field(
        default_factory=lambda: _env("REGISTRY", default="legleux")
    )
    build_image: str = field(
        default_factory=lambda: _env(
            "BUILD_IMAGE", default="ghcr.io/xrplf/ci/ubuntu-jammy:gcc-12"
        )
    )
    conan_remote: str = field(
        default_factory=lambda: _env("CONAN_REMOTE", default="conan.ripplex.io")
    )

    @property
    def image(self) -> str:
        return f"{self.registry}/{self.repo}"

    @property
    def target(self) -> str:
        return "xrpld-slim" if self.slim else "xrpld"


@dataclass
class BuildResult:
    """Prepared build ready for execution."""

    command: list[str]
    image_tag: str
    worktree_path: Path
    commit_hash: str


def prepare_build(config: BuildConfig, base_dir: Path | None = None) -> BuildResult:
    """Set up worktree, apply patches, and assemble docker build command.

    Does NOT execute the build — call run_build() or run the command yourself.
    """
    base = base_dir or Path.cwd()

    wt = setup_worktree(
        owner=config.owner,
        repo=config.repo,
        branch=config.branch if not config.git_hash else None,
        git_hash=config.git_hash,
        base_dir=base,
    )

    source_path = wt.path.relative_to(base)
    sanitized = config.branch.replace("/", "--")

    _apply_patches(base, config.owner, config.repo, config.branch, wt.path)

    dockerfile = _resolve_dockerfile(base, config.owner, sanitized)

    # Image tag: CI uses hash-arch, local uses branch name
    arch = "arm64" if platform.machine() == "aarch64" else "amd64"
    if os.environ.get("CI"):
        raw_tag = f"{wt.commit_hash}-{arch}"
    else:
        raw_tag = config.branch
    tag = raw_tag.replace("/", "--").replace("-", "_")
    image_tag = f"{config.image}:{tag}"

    # Assemble docker build command
    cmd = ["docker", "build", str(base)]
    cmd += ["--tag", image_tag]
    cmd += [f"--memory={config.mem_limit}g", f"--memory-swap={config.mem_limit}g"]
    cmd += [f"--target={config.target}"]

    if dockerfile:
        cmd += ["--file", str(dockerfile)]
    if config.no_cache:
        cmd.append("--no-cache")

    # Build args
    build_args = {
        "branch": config.branch,
        "git_hash": wt.commit_hash,
        "source_path": str(source_path),
        "BUILD_IMAGE": config.build_image,
        "CONAN_REMOTE": config.conan_remote,
        "repo": f"{config.owner}/{config.repo}",
        "NPROC": str(config.nproc),
        "BUILD_TESTS": str(config.build_tests),
    }
    for key, val in build_args.items():
        cmd += ["--build-arg", f"{key}={val}"]

    # Labels
    labels = [
        f"com.ripple.branch={config.branch}",
        f"com.ripple.commit_id={wt.commit_hash}",
        f"com.ripple.repo_url=https://github.com/{config.owner}/{config.repo}.git",
    ]
    for label in labels:
        cmd += ["--label", label]

    # Extra tags/labels from user
    for t in _split_csv(config.extra_tags):
        cmd += ["--tag", t]
    for lbl in _split_csv(config.extra_labels):
        cmd += ["--label", lbl]

    cmd.append("--push" if config.push else "--load")

    return BuildResult(
        command=cmd,
        image_tag=image_tag,
        worktree_path=wt.path,
        commit_hash=wt.commit_hash,
    )


def run_build(result: BuildResult) -> subprocess.CompletedProcess:
    """Execute a prepared docker build."""
    return subprocess.run(result.command, check=True)


# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------


def _split_csv(value: str) -> list[str]:
    """Split comma-separated string, stripping whitespace and dropping empties."""
    return [v.strip() for v in value.split(",") if v.strip()] if value else []


def _apply_patches(
    base: Path, owner: str, repo: str, branch: str, worktree: Path
) -> None:
    """Apply branch-specific .patch files to the worktree.

    Searches branches/<owner>/<repo>/<branch>/ for top-level .patch files
    and applies them with git apply. Already-applied patches are skipped.
    """
    patch_dir = _find_branch_dir(base, owner, repo, branch)
    if not patch_dir:
        return

    for patch in sorted(patch_dir.glob("*.patch")):
        check = subprocess.run(
            ["git", "-C", str(worktree), "apply", "--check", str(patch)],
            capture_output=True,
        )
        if check.returncode == 0:
            print(f"Applying patch: {patch}")
            subprocess.run(
                ["git", "-C", str(worktree), "apply", str(patch)], check=True
            )
        else:
            print(f"Patch already applied or N/A: {patch}")


def _find_branch_dir(base: Path, owner: str, repo: str, branch: str) -> Path | None:
    """Locate the branch-specific customization directory.

    Checks multiple conventions:
      branches/<owner>/<repo>/<branch>/   (current layout on disk)
      branches/<owner>/<sanitized>/       (CLAUDE.md documented convention)
    """
    sanitized = branch.replace("/", "--")
    candidates = [
        base / "branches" / owner / repo / branch,
        base / "branches" / owner / sanitized,
    ]
    for path in candidates:
        if path.is_dir():
            return path
    return None


def _resolve_dockerfile(base: Path, owner: str, sanitized_branch: str) -> Path | None:
    """Check for a per-branch Dockerfile on a build/<owner>/<branch> git branch."""
    build_branch = f"build/{owner}/{sanitized_branch}"
    result = subprocess.run(
        ["git", "rev-parse", "--verify", build_branch],
        capture_output=True,
        cwd=base,
    )
    if result.returncode != 0:
        return None

    show = subprocess.run(
        ["git", "show", f"{build_branch}:Dockerfile"],
        capture_output=True,
        text=True,
        cwd=base,
    )
    if show.returncode != 0:
        return None

    tmp = Path("/tmp/Dockerfile.build")
    tmp.write_text(show.stdout)
    print(f"Using Dockerfile from branch: {build_branch}")
    return tmp
