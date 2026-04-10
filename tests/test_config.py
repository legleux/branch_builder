"""Tests for BuildConfig defaults, env var fallbacks, and derived properties."""

import os

import pytest

from builder import BuildConfig


@pytest.fixture(autouse=True)
def _clean_env(monkeypatch):
    """Strip builder-relevant env vars so tests start from a known state."""
    for var in (
        "REPO_OWNER", "GITHUB_REPOSITORY_OWNER",
        "BRANCH", "GITHUB_REF_NAME",
        "GIT_HASH", "GITHUB_SHA",
        "NPROC", "MEM_LIMIT",
        "REGISTRY", "BUILD_IMAGE", "CONAN_REMOTE",
    ):
        monkeypatch.delenv(var, raising=False)


class TestDefaults:
    def test_defaults(self):
        c = BuildConfig()
        assert c.owner == "XRPLF"
        assert c.branch == "develop"
        assert c.git_hash is None
        assert c.nproc == 24
        assert c.mem_limit == 50

    def test_image_property(self):
        c = BuildConfig(registry="myregistry", repo="rippled")
        assert c.image == "myregistry/rippled"

    def test_target_default(self):
        assert BuildConfig().target == "xrpld"

    def test_target_slim(self):
        assert BuildConfig(slim=True).target == "xrpld-slim"


class TestEnvVarFallbacks:
    def test_repo_owner_env(self, monkeypatch):
        monkeypatch.setenv("REPO_OWNER", "Transia-RnD")
        assert BuildConfig().owner == "Transia-RnD"

    def test_github_owner_fallback(self, monkeypatch):
        monkeypatch.setenv("GITHUB_REPOSITORY_OWNER", "yinyiqian1")
        assert BuildConfig().owner == "yinyiqian1"

    def test_repo_owner_beats_github(self, monkeypatch):
        monkeypatch.setenv("REPO_OWNER", "custom")
        monkeypatch.setenv("GITHUB_REPOSITORY_OWNER", "github-val")
        assert BuildConfig().owner == "custom"

    def test_branch_env(self, monkeypatch):
        monkeypatch.setenv("BRANCH", "feature-batch")
        assert BuildConfig().branch == "feature-batch"

    def test_github_ref_name_fallback(self, monkeypatch):
        monkeypatch.setenv("GITHUB_REF_NAME", "main")
        assert BuildConfig().branch == "main"

    def test_branch_beats_github_ref(self, monkeypatch):
        monkeypatch.setenv("BRANCH", "custom-branch")
        monkeypatch.setenv("GITHUB_REF_NAME", "github-branch")
        assert BuildConfig().branch == "custom-branch"

    def test_git_hash_env(self, monkeypatch):
        monkeypatch.setenv("GIT_HASH", "abc123")
        assert BuildConfig().git_hash == "abc123"

    def test_github_sha_not_auto_used(self, monkeypatch):
        """GITHUB_SHA should NOT be picked up — it's always set in CI
        and would conflict with the branch default."""
        monkeypatch.setenv("GITHUB_SHA", "deadbeef")
        assert BuildConfig().git_hash is None

    def test_nproc_env(self, monkeypatch):
        monkeypatch.setenv("NPROC", "8")
        assert BuildConfig().nproc == 8

    def test_mem_limit_env(self, monkeypatch):
        monkeypatch.setenv("MEM_LIMIT", "32")
        assert BuildConfig().mem_limit == 32

    def test_registry_env(self, monkeypatch):
        monkeypatch.setenv("REGISTRY", "ghcr.io/myorg")
        assert BuildConfig().registry == "ghcr.io/myorg"

    def test_build_image_env(self, monkeypatch):
        monkeypatch.setenv("BUILD_IMAGE", "my-image:latest")
        assert BuildConfig().build_image == "my-image:latest"

    def test_conan_remote_env(self, monkeypatch):
        monkeypatch.setenv("CONAN_REMOTE", "my.conan.server")
        assert BuildConfig().conan_remote == "my.conan.server"


class TestExplicitOverridesEnv:
    def test_explicit_owner_overrides_env(self, monkeypatch):
        monkeypatch.setenv("REPO_OWNER", "env-owner")
        c = BuildConfig(owner="explicit-owner")
        assert c.owner == "explicit-owner"

    def test_explicit_branch_overrides_env(self, monkeypatch):
        monkeypatch.setenv("BRANCH", "env-branch")
        c = BuildConfig(branch="explicit-branch")
        assert c.branch == "explicit-branch"
