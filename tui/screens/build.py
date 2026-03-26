"""Build execution screen with live log output."""

import asyncio
import json
import os
import subprocess

from textual.app import ComposeResult
from textual.containers import Vertical
from textual.screen import Screen
from textual.widgets import (
    Collapsible,
    Footer,
    Header,
    RichLog,
    Static,
    Tree,
)


class BuildScreen(Screen):
    BINDINGS = [
        ("escape", "cancel_build", "Cancel"),
        ("q", "app.quit", "Quit"),
    ]

    CSS = """
    BuildScreen {
        layout: vertical;
    }
    #build-status {
        dock: top;
        height: 3;
        padding: 1;
        background: $surface;
    }
    #build-log {
        height: 1fr;
    }
    #image-info {
        height: auto;
        max-height: 50%;
        display: none;
    }
    #image-summary {
        padding: 1;
        height: auto;
    }
    #inspect-tree {
        height: auto;
        max-height: 30;
    }
    """

    def __init__(self, config: dict | None = None):
        super().__init__()
        self.config = config or {}
        self._process: asyncio.subprocess.Process | None = None
        self._image_name: str = ""

    def compose(self) -> ComposeResult:
        yield Header()
        yield Static(self._status_text(), id="build-status")
        yield RichLog(highlight=True, markup=True, id="build-log")
        with Vertical(id="image-info"):
            yield Static("", id="image-summary")
            with Collapsible(title="Docker Inspect", collapsed=True):
                yield Tree("inspect", id="inspect-tree")
        yield Footer()

    def _status_text(self) -> str:
        owner = self.config.get("owner", "?")
        branch = self.config.get("branch", "?")
        return f"Building [bold]{owner}/{branch}[/] ..."

    async def on_mount(self) -> None:
        asyncio.create_task(self.run_build())

    async def run_build(self) -> None:
        log = self.query_one("#build-log", RichLog)
        status = self.query_one("#build-status", Static)

        env = os.environ.copy()
        env.update(self._build_env())

        cmd = "./build_image.sh"
        log.write(f"[dim]$ {' '.join(f'{k}={v}' for k, v in self._build_env().items())} {cmd}[/]")
        log.write("")

        try:
            self._process = await asyncio.create_subprocess_exec(
                "bash", cmd,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.STDOUT,
                env=env,
            )

            async for line in self._process.stdout:
                text = line.decode().rstrip()
                log.write(text)
                if text.startswith("Final image name:"):
                    self._image_name = text.split(":", 1)[1].strip()

            await self._process.wait()

            if self._process.returncode == 0:
                status.update("[green bold]Build succeeded![/]")
                await self._show_image_info()
            else:
                status.update(
                    f"[red bold]Build failed (exit {self._process.returncode})[/]"
                )
        except Exception as e:
            status.update(f"[red bold]Error: {e}[/]")
        finally:
            self._process = None

    async def _show_image_info(self) -> None:
        if not self._image_name:
            return

        result = subprocess.run(
            ["docker", "inspect", self._image_name],
            capture_output=True, text=True,
        )
        if result.returncode != 0:
            return

        inspect_data = json.loads(result.stdout)
        if not inspect_data:
            return

        info = inspect_data[0]
        tags = info.get("RepoTags", [])
        size_mb = info.get("Size", 0) / 1_000_000
        image_id = info.get("Id", "")[:19]

        summary = (
            f"[bold]Image:[/] {self._image_name}\n"
            f"[bold]ID:[/] {image_id}\n"
            f"[bold]Size:[/] {size_mb:.1f} MB\n"
            f"[bold]Tags:[/] {', '.join(tags) or 'none'}"
        )
        self.query_one("#image-summary", Static).update(summary)

        tree = self.query_one("#inspect-tree", Tree)
        tree.clear()
        self._build_tree(tree.root, info)
        tree.root.expand()

        self.query_one("#image-info").styles.display = "block"

    def _build_tree(self, node, data, key: str = "") -> None:
        if isinstance(data, dict):
            for k, v in data.items():
                if isinstance(v, (dict, list)) and v:
                    child = node.add(f"[bold]{k}[/]")
                    self._build_tree(child, v, k)
                else:
                    node.add_leaf(f"[bold]{k}:[/] {v}")
        elif isinstance(data, list):
            for i, item in enumerate(data):
                if isinstance(item, (dict, list)) and item:
                    child = node.add(f"[dim]{i}[/]")
                    self._build_tree(child, item)
                else:
                    node.add_leaf(f"[dim]{i}:[/] {item}")

    def _build_env(self) -> dict[str, str]:
        return {
            "BUILDKIT_PROGRESS": "plain",
            "REPO_OWNER": self.config.get("owner", "XRPLF"),
            "BRANCH": self.config.get("branch", "develop"),
            "NPROC": str(self.config.get("nproc", "16")),
            "MEM_LIMIT": str(self.config.get("mem_limit", "50")),
            "DOCKER_DEFAULT_PLATFORM": "linux/amd64",
            **({"PUSH": "true"} if self.config.get("push") else {}),
            **({"DRY_RUN": "true"} if self.config.get("dry_run") else {}),
            **({"ADD_TAGS": self.config["extra_tags"]} if self.config.get("extra_tags") else {}),
            **({"ADD_LABELS": self.config["extra_labels"]} if self.config.get("extra_labels") else {}),
            **({"DOCKER_TARGET": "xrpld-slim"} if self.config.get("slim") else {"DOCKER_TARGET": "xrpld"}),
        }

    def action_cancel_build(self) -> None:
        if self._process:
            self._process.terminate()
        self.app.pop_screen()
