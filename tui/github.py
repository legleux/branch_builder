"""GitHub CLI wrapper for querying repos, branches, and PRs."""

import json
import subprocess


BASE_REPO = "XRPLF/rippled"
_org_members: set[str] | None = None


def get_org_members(org: str = "ripple") -> set[str]:
    """Get members of a GitHub org. Cached after first call."""
    global _org_members
    if _org_members is not None:
        return _org_members
    result = subprocess.run(
        ["gh", "api", f"orgs/{org}/members", "--paginate", "-q", ".[].login"],
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        _org_members = set()
    else:
        _org_members = {m for m in result.stdout.strip().split('\n') if m}
    return _org_members


def is_ripple_member(login: str) -> bool:
    """Check if a user is a member of the Ripple org."""
    return login in get_org_members()


def check_auth() -> bool:
    """Check if gh is authenticated."""
    result = subprocess.run(
        ["gh", "auth", "status"], capture_output=True, text=True
    )
    return result.returncode == 0


def list_forks() -> list[dict]:
    """List forks of the base repo."""
    result = subprocess.run(
        ["gh", "api", f"repos/{BASE_REPO}/forks", "--paginate", "-q",
         '[.[] | {owner: .owner.login, full_name: .full_name}]'],
        capture_output=True, text=True
    )
    if result.returncode != 0:
        return []
    forks = []
    for line in result.stdout.strip().split('\n'):
        if line:
            forks.extend(json.loads(line))
    # Include the base repo itself
    owner = BASE_REPO.split("/")[0]
    forks.insert(0, {"owner": owner, "full_name": BASE_REPO})
    return forks


def list_branches(owner: str, repo: str = "rippled") -> list[str]:
    """List branches for a given owner/repo."""
    result = subprocess.run(
        ["gh", "api", f"repos/{owner}/{repo}/branches", "--paginate",
         "-q", ".[].name"],
        capture_output=True, text=True
    )
    if result.returncode != 0:
        return []
    return [b for b in result.stdout.strip().split('\n') if b]


def list_prs(state: str = "open") -> list[dict]:
    """List PRs on the base repo."""
    result = subprocess.run(
        ["gh", "pr", "list", "--repo", BASE_REPO, "--state", state,
         "--json", "number,title,headRefName,headRepositoryOwner,author",
         "--limit", "50"],
        capture_output=True, text=True
    )
    if result.returncode != 0:
        return []
    return json.loads(result.stdout)
