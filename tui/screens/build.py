"""Build execution screen with live log output."""

import asyncio
import json
import os
import subprocess
from datetime import datetime
from pathlib import Path

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

from builder import BuildConfig, prepare_build


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

        build_config = BuildConfig(
            owner=self.config.get("owner", "XRPLF"),
            branch=self.config.get("branch", "develop"),
            nproc=int(self.config.get("nproc", 16)),
            mem_limit=int(self.config.get("mem_limit", 50)),
            push=bool(self.config.get("push")),
            dry_run=bool(self.config.get("dry_run")),
            build_tests=bool(self.config.get("tests")),
            slim=bool(self.config.get("slim")),
            extra_tags=self.config.get("extra_tags", ""),
            extra_labels=self.config.get("extra_labels", ""),
        )

        # Prepare build (worktree setup, patches, command assembly)
        status.update(
            f"Preparing [bold]{build_config.owner}/{build_config.branch}[/] ..."
        )
        try:
            result = await asyncio.to_thread(prepare_build, build_config)
        except Exception as e:
            status.update(f"[red bold]Preparation failed: {e}[/]")
            return

        self._image_name = result.image_tag

        # Set up log file
        log_dir = Path("logs")
        log_dir.mkdir(exist_ok=True)
        owner = self.config.get("owner", "unknown")
        branch = self.config.get("branch", "unknown").replace("/", "--")
        timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
        log_path = log_dir / f"{owner}_{branch}_{timestamp}.log"
        log_file = open(log_path, "w")

        cmd_str = " ".join(result.command)
        log.write(f"[dim]$ {cmd_str}[/]")
        log.write("")
        log_file.write(f"$ {cmd_str}\n\n")

        if build_config.dry_run:
            status.update("[yellow]Dry run — command printed above[/]")
            log_file.close()
            return

        try:
            env = {**os.environ, "BUILDKIT_PROGRESS": "plain"}
            self._process = await asyncio.create_subprocess_exec(
                *result.command,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.STDOUT,
                env=env,
            )

            async for line in self._process.stdout:
                text = line.decode().rstrip()
                log.write(text)
                log_file.write(text + "\n")

            await self._process.wait()

            if self._process.returncode == 0:
                status.update(f"[green bold]Build succeeded![/] Log: {log_path}")
                await self._show_image_info()
            else:
                status.update(
                    f"[red bold]Build failed (exit {self._process.returncode})[/] Log: {log_path}"
                )
        except Exception as e:
            status.update(f"[red bold]Error: {e}[/]")
        finally:
            log_file.close()
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

    def action_cancel_build(self) -> None:
        if self._process:
            self._process.terminate()
        self.app.pop_screen()
