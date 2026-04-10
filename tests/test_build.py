"""Tests for prepare_build command assembly."""

import os
from pathlib import Path
from unittest.mock import patch

import pytest

from builder import BuildConfig, BuildResult, prepare_build
from builder.worktree import WorktreeResult


@pytest.fixture(autouse=True)
def _clean_env(monkeypatch):
    for var in (
        "REPO_OWNER", "GITHUB_REPOSITORY_OWNER",
        "BRANCH", "GITHUB_REF_NAME",
        "GIT_HASH", "NPROC", "MEM_LIMIT",
        "REGISTRY", "BUILD_IMAGE", "CONAN_REMOTE", "CI",
    ):
        monkeypatch.delenv(var, raising=False)


@pytest.fixture
def mock_worktree(tmp_path):
    """Patch setup_worktree to return a fake worktree without hitting git."""
    wt_path = tmp_path / "worktrees" / "XRPLF" / "develop"
    wt_path.mkdir(parents=True)
    fake_result = WorktreeResult(
        path=wt_path,
        commit_hash="aabbccdd11223344556677889900aabbccddeeff",
    )
    with patch("builder.setup_worktree", return_value=fake_result) as mock:
        yield mock, fake_result


class TestCommandAssembly:
    def test_returns_build_result(self, tmp_path, mock_worktree):
        config = BuildConfig(owner="XRPLF", branch="develop")
        result = prepare_build(config, base_dir=tmp_path)
        assert isinstance(result, BuildResult)
        assert result.commit_hash == "aabbccdd11223344556677889900aabbccddeeff"

    def test_image_tag_from_branch(self, tmp_path, mock_worktree):
        config = BuildConfig(branch="develop", registry="myregistry", repo="rippled")
        result = prepare_build(config, base_dir=tmp_path)
        assert result.image_tag == "myregistry/rippled:develop"

    def test_image_tag_sanitizes_slashes(self, tmp_path, mock_worktree):
        _, fake = mock_worktree
        # Re-mock with a slash-branch worktree path
        wt_path = tmp_path / "worktrees" / "XRPLF" / "ripple--smart-escrow"
        wt_path.mkdir(parents=True)
        fake.path = wt_path

        config = BuildConfig(branch="ripple/smart-escrow", registry="r", repo="rippled")
        result = prepare_build(config, base_dir=tmp_path)
        assert "ripple__smart_escrow" in result.image_tag

    def test_image_tag_ci_uses_hash(self, tmp_path, mock_worktree, monkeypatch):
        monkeypatch.setenv("CI", "true")
        config = BuildConfig(branch="develop", registry="r", repo="rippled")
        result = prepare_build(config, base_dir=tmp_path)
        assert "aabbccdd" in result.image_tag

    def test_command_has_docker_build(self, tmp_path, mock_worktree):
        config = BuildConfig()
        result = prepare_build(config, base_dir=tmp_path)
        assert result.command[0] == "docker"
        assert result.command[1] == "build"

    def test_command_has_memory_limits(self, tmp_path, mock_worktree):
        config = BuildConfig(mem_limit=32)
        result = prepare_build(config, base_dir=tmp_path)
        assert "--memory=32g" in result.command
        assert "--memory-swap=32g" in result.command

    def test_command_has_target(self, tmp_path, mock_worktree):
        config = BuildConfig(slim=False)
        result = prepare_build(config, base_dir=tmp_path)
        assert "--target=xrpld" in result.command

    def test_command_slim_target(self, tmp_path, mock_worktree):
        config = BuildConfig(slim=True)
        result = prepare_build(config, base_dir=tmp_path)
        assert "--target=xrpld-slim" in result.command

    def test_command_has_load_by_default(self, tmp_path, mock_worktree):
        config = BuildConfig()
        result = prepare_build(config, base_dir=tmp_path)
        assert "--load" in result.command
        assert "--push" not in result.command

    def test_command_has_push(self, tmp_path, mock_worktree):
        config = BuildConfig(push=True)
        result = prepare_build(config, base_dir=tmp_path)
        assert "--push" in result.command
        assert "--load" not in result.command

    def test_command_no_cache(self, tmp_path, mock_worktree):
        config = BuildConfig(no_cache=True)
        result = prepare_build(config, base_dir=tmp_path)
        assert "--no-cache" in result.command

    def test_no_cache_absent_by_default(self, tmp_path, mock_worktree):
        config = BuildConfig()
        result = prepare_build(config, base_dir=tmp_path)
        assert "--no-cache" not in result.command


class TestBuildArgs:
    def test_build_args_present(self, tmp_path, mock_worktree):
        config = BuildConfig(owner="XRPLF", branch="develop", nproc=16)
        result = prepare_build(config, base_dir=tmp_path)
        cmd = result.command

        # Find all --build-arg values
        build_args = {}
        it = iter(cmd)
        for token in it:
            if token == "--build-arg":
                kv = next(it)
                k, v = kv.split("=", 1)
                build_args[k] = v

        assert build_args["branch"] == "develop"
        assert build_args["NPROC"] == "16"
        assert build_args["repo"] == "XRPLF/rippled"
        assert "git_hash" in build_args
        assert "source_path" in build_args
        assert "BUILD_IMAGE" in build_args
        assert "CONAN_REMOTE" in build_args


class TestLabels:
    def test_default_labels(self, tmp_path, mock_worktree):
        config = BuildConfig(owner="XRPLF", branch="develop")
        result = prepare_build(config, base_dir=tmp_path)
        cmd = result.command

        labels = []
        it = iter(cmd)
        for token in it:
            if token == "--label":
                labels.append(next(it))

        assert any("com.ripple.branch=develop" in l for l in labels)
        assert any("com.ripple.commit_id=" in l for l in labels)
        assert any("com.ripple.repo_url=" in l for l in labels)

    def test_extra_labels_are_key_value(self, tmp_path, mock_worktree):
        config = BuildConfig(extra_labels="env=staging,team=infra")
        result = prepare_build(config, base_dir=tmp_path)
        cmd = result.command

        labels = []
        it = iter(cmd)
        for token in it:
            if token == "--label":
                labels.append(next(it))

        assert "env=staging" in labels
        assert "team=infra" in labels


class TestExtraTags:
    def test_extra_tags(self, tmp_path, mock_worktree):
        config = BuildConfig(extra_tags="myregistry/xrpld:latest,myregistry/xrpld:v2")
        result = prepare_build(config, base_dir=tmp_path)
        cmd = result.command

        tags = []
        it = iter(cmd)
        for token in it:
            if token == "--tag":
                tags.append(next(it))

        assert "myregistry/xrpld:latest" in tags
        assert "myregistry/xrpld:v2" in tags

    def test_empty_extra_tags_adds_nothing(self, tmp_path, mock_worktree):
        config = BuildConfig(extra_tags="")
        result = prepare_build(config, base_dir=tmp_path)
        # Only the primary tag, no extras
        tag_count = sum(1 for t in result.command if t == "--tag")
        assert tag_count == 1


class TestPatches:
    def test_patches_applied(self, tmp_path, mock_worktree):
        """Patches in branches/<owner>/<repo>/<branch>/ should be applied."""
        _, fake = mock_worktree

        # Create a fake worktree with git init
        wt = fake.path
        os.system(f"git init -q {wt}")
        os.system(f"git -C {wt} commit --allow-empty -m init -q")

        # Create a file and a patch
        (wt / "hello.txt").write_text("original\n")
        os.system(f"git -C {wt} add hello.txt && git -C {wt} commit -m add -q")

        patch_dir = tmp_path / "branches" / "XRPLF" / "rippled" / "develop"
        patch_dir.mkdir(parents=True)
        (patch_dir / "fix.patch").write_text(
            "--- a/hello.txt\n"
            "+++ b/hello.txt\n"
            "@@ -1 +1 @@\n"
            "-original\n"
            "+patched\n"
        )

        config = BuildConfig(owner="XRPLF", branch="develop")
        prepare_build(config, base_dir=tmp_path)

        assert (wt / "hello.txt").read_text() == "patched\n"

    def test_no_patch_dir_is_fine(self, tmp_path, mock_worktree):
        """Missing patch directory should not error."""
        config = BuildConfig(owner="XRPLF", branch="develop")
        result = prepare_build(config, base_dir=tmp_path)
        assert result is not None
