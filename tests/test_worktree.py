"""Integration tests for worktree management — uses real git operations."""

import subprocess
from dataclasses import dataclass
from pathlib import Path

import pytest

from builder.worktree import WorktreeResult, setup_worktree


@dataclass
class SourceRepo:
    path: Path
    initial_hash: str
    feature_hash: str


@pytest.fixture
def source_repo(tmp_path) -> SourceRepo:
    """Create a source git repo with a branch, tag, and known commits."""
    repo = tmp_path / "source"
    repo.mkdir()

    def git(*args):
        subprocess.run(["git", "-C", str(repo), *args], check=True, capture_output=True)

    def git_output(*args) -> str:
        return subprocess.run(
            ["git", "-C", str(repo), *args],
            check=True, capture_output=True, text=True,
        ).stdout.strip()

    git("init", "-q", "-b", "main")
    git("commit", "--allow-empty", "-m", "initial", "-q")
    initial_hash = git_output("rev-parse", "HEAD")

    # Annotated tag (tag object != commit)
    git("tag", "-a", "v1.0.0", "-m", "release v1.0.0")

    # Feature branch with another commit
    git("checkout", "-b", "feature/foo", "-q")
    git("commit", "--allow-empty", "-m", "feature work", "-q")
    feature_hash = git_output("rev-parse", "HEAD")

    git("checkout", "main", "-q")

    return SourceRepo(path=repo, initial_hash=initial_hash, feature_hash=feature_hash)


@pytest.fixture
def project_dir(tmp_path, source_repo) -> Path:
    """Set up a project directory with a bare repo pointing at source_repo."""
    project = tmp_path / "project"
    project.mkdir()

    bare = project / "repos" / "myrepo.git"
    bare.parent.mkdir(parents=True)
    subprocess.run(["git", "init", "--bare", str(bare)], check=True, capture_output=True)
    subprocess.run(
        ["git", "-C", str(bare), "remote", "add", "testowner", f"file://{source_repo.path}"],
        check=True, capture_output=True,
    )
    subprocess.run(
        ["git", "-C", str(bare), "fetch", "testowner", "--tags"],
        check=True, capture_output=True,
    )
    subprocess.run(
        ["git", "-C", str(bare), "fetch", "testowner"],
        check=True, capture_output=True,
    )

    return project


class TestBranchCheckout:
    def test_creates_worktree(self, project_dir, source_repo):
        result = setup_worktree(
            owner="testowner", repo="myrepo",
            branch="main", base_dir=project_dir,
        )
        assert isinstance(result, WorktreeResult)
        assert result.path.exists()
        assert result.commit_hash == source_repo.initial_hash

    def test_worktree_path_convention(self, project_dir, source_repo):
        result = setup_worktree(
            owner="testowner", repo="myrepo",
            branch="main", base_dir=project_dir,
        )
        assert result.path == project_dir / "worktrees" / "testowner" / "main"

    def test_slash_branch_sanitized(self, project_dir, source_repo):
        result = setup_worktree(
            owner="testowner", repo="myrepo",
            branch="feature/foo", base_dir=project_dir,
        )
        assert result.path == project_dir / "worktrees" / "testowner" / "feature--foo"
        assert result.commit_hash == source_repo.feature_hash

    def test_idempotent(self, project_dir, source_repo):
        """Calling setup_worktree twice with the same ref is a no-op."""
        r1 = setup_worktree(
            owner="testowner", repo="myrepo",
            branch="main", base_dir=project_dir,
        )
        r2 = setup_worktree(
            owner="testowner", repo="myrepo",
            branch="main", base_dir=project_dir,
        )
        assert r1.commit_hash == r2.commit_hash
        assert r1.path == r2.path


class TestTagCheckout:
    def test_annotated_tag_resolves_to_commit(self, project_dir, source_repo):
        """Annotated tags must dereference to the commit, not the tag object."""
        result = setup_worktree(
            owner="testowner", repo="myrepo",
            branch="v1.0.0", base_dir=project_dir,
        )
        assert result.commit_hash == source_repo.initial_hash

    def test_tag_worktree_path(self, project_dir, source_repo):
        result = setup_worktree(
            owner="testowner", repo="myrepo",
            branch="v1.0.0", base_dir=project_dir,
        )
        assert result.path == project_dir / "worktrees" / "testowner" / "v1.0.0"


class TestHashCheckout:
    def test_checkout_by_hash(self, project_dir, source_repo):
        result = setup_worktree(
            owner="testowner", repo="myrepo",
            git_hash=source_repo.feature_hash, base_dir=project_dir,
        )
        assert result.commit_hash == source_repo.feature_hash
        assert "commit-" in result.path.name


class TestValidation:
    def test_neither_branch_nor_hash_raises(self, project_dir):
        with pytest.raises(ValueError, match="Either branch or git_hash"):
            setup_worktree(owner="x", repo="y", base_dir=project_dir)

    def test_both_branch_and_hash_raises(self, project_dir):
        with pytest.raises(ValueError, match="either branch or git_hash"):
            setup_worktree(
                owner="x", repo="y",
                branch="main", git_hash="abc",
                base_dir=project_dir,
            )

    def test_nonexistent_ref_raises(self, project_dir, source_repo):
        with pytest.raises(RuntimeError):
            setup_worktree(
                owner="testowner", repo="myrepo",
                branch="does-not-exist", base_dir=project_dir,
            )
