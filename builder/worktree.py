"""Git worktree management using a bare repo with multiple remotes."""

from __future__ import annotations

import subprocess
from dataclasses import dataclass
from pathlib import Path


@dataclass
class WorktreeResult:
    """Result of worktree setup."""

    path: Path
    commit_hash: str


def setup_worktree(
    owner: str,
    repo: str,
    *,
    branch: str | None = None,
    git_hash: str | None = None,
    base_dir: Path | None = None,
) -> WorktreeResult:
    """Set up a git worktree for the given owner/repo/ref.

    Manages a single bare repo (repos/<repo>.git) with one remote per fork
    owner. Creates/updates worktrees under worktrees/<owner>/<branch>/.
    Supports branches, tags (dereferenced to commits), and raw commit hashes.
    """
    if not branch and not git_hash:
        raise ValueError("Either branch or git_hash must be provided")
    if branch and git_hash:
        raise ValueError("Provide either branch or git_hash, not both")

    base = base_dir or Path.cwd()
    bare_repo = base / "repos" / f"{repo}.git"
    remote_url = f"https://github.com/{owner}/{repo}.git"

    # Init bare repo if needed
    if not bare_repo.exists():
        bare_repo.parent.mkdir(parents=True, exist_ok=True)
        _run_git("init", "--bare", str(bare_repo))

    # Add remote if needed
    if not _remote_exists(bare_repo, owner):
        _run_git("-C", str(bare_repo), "remote", "add", owner, remote_url)

    if git_hash:
        return _setup_by_hash(bare_repo, owner, git_hash, base)
    return _setup_by_branch(bare_repo, owner, branch, base)


def _setup_by_hash(
    bare_repo: Path, owner: str, git_hash: str, base: Path
) -> WorktreeResult:
    _run_git("-C", str(bare_repo), "fetch", owner, git_hash)

    short = git_hash[:12]
    wt_path = base / "worktrees" / owner / f"commit-{short}"

    _ensure_worktree(bare_repo, wt_path, git_hash, git_hash)
    return WorktreeResult(path=wt_path, commit_hash=git_hash)


def _setup_by_branch(
    bare_repo: Path, owner: str, branch: str, base: Path
) -> WorktreeResult:
    result = subprocess.run(
        ["git", "-C", str(bare_repo), "fetch", owner, branch],
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        raise RuntimeError(
            f"Failed to fetch '{branch}' from {owner}: {result.stderr.strip()}"
        )

    ref = _resolve_ref(bare_repo, owner, branch)
    # Dereference annotated tags to the underlying commit
    commit = _git_output("-C", str(bare_repo), "rev-parse", f"{ref}^{{commit}}")

    sanitized = branch.replace("/", "--")
    wt_path = base / "worktrees" / owner / sanitized

    _ensure_worktree(bare_repo, wt_path, ref, commit)
    return WorktreeResult(path=wt_path, commit_hash=commit)


def _ensure_worktree(
    bare_repo: Path, wt_path: Path, ref: str, expected_hash: str
) -> None:
    if not wt_path.exists():
        wt_path.parent.mkdir(parents=True, exist_ok=True)
        _run_git(
            "-C", str(bare_repo), "worktree", "add", str(wt_path), ref, "--detach"
        )
    else:
        current = _git_output("-C", str(wt_path), "rev-parse", "HEAD")
        if current != expected_hash:
            _run_git("-C", str(wt_path), "checkout", "--detach", ref)


def _resolve_ref(bare_repo: Path, remote: str, branch: str) -> str:
    """Resolve a branch/tag name to a full git ref."""
    repo_str = str(bare_repo)
    for ref in (f"refs/remotes/{remote}/{branch}", f"refs/tags/{branch}"):
        if _ref_exists(repo_str, ref):
            return ref
    raise RuntimeError(f"'{branch}' not found as branch or tag on {remote}")


def _ref_exists(repo: str, ref: str) -> bool:
    return (
        subprocess.run(
            ["git", "-C", repo, "rev-parse", "--verify", ref],
            capture_output=True,
        ).returncode
        == 0
    )


def _remote_exists(bare_repo: Path, name: str) -> bool:
    return (
        subprocess.run(
            ["git", "-C", str(bare_repo), "remote", "get-url", name],
            capture_output=True,
        ).returncode
        == 0
    )


def _run_git(*args: str) -> None:
    subprocess.run(["git", *args], check=True)


def _git_output(*args: str) -> str:
    return subprocess.run(
        ["git", *args], capture_output=True, text=True, check=True
    ).stdout.strip()
