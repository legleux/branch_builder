"""Build options screen."""

from textual.app import ComposeResult
from textual.containers import Horizontal, Vertical
from textual.screen import Screen
from textual.widgets import (
    Button,
    Checkbox,
    Footer,
    Header,
    Input,
    Label,
    Static,
)


class OptionsScreen(Screen):
    BINDINGS = [
        ("escape", "go_back", "Back"),
    ]

    CSS = """
    OptionsScreen {
        layout: vertical;
        padding: 1 2;
    }
    #summary {
        margin: 0 0 1 0;
        padding: 1;
        border: solid $primary;
        height: auto;
    }
    #columns {
        height: auto;
    }
    #left-col {
        width: 1fr;
        height: auto;
        padding: 0 2 0 0;
    }
    #right-col {
        width: 1fr;
        height: auto;
    }
    .field {
        height: auto;
        margin: 0 0 1 0;
    }
    .field Label {
        margin: 0 0 0 0;
    }
    .field Input {
        width: 100%;
    }
    #toggles {
        height: auto;
        margin: 0 0 1 0;
    }
    #toggles Checkbox {
        height: auto;
        margin: 0 2 0 0;
    }
    #build-btn {
        margin: 1 0;
        width: 20;
    }
    """

    def __init__(self, config: dict | None = None):
        super().__init__()
        self.config = config or {}

    def compose(self) -> ComposeResult:
        yield Header()
        yield Static(
            f"Building: [bold]{self.config.get('owner', '?')}/{self.config.get('branch', '?')}[/]",
            id="summary",
        )
        with Horizontal(id="columns"):
            with Vertical(id="left-col"):
                with Vertical(classes="field"):
                    yield Label("NPROC")
                    yield Input(value="16", id="nproc")
                with Vertical(classes="field"):
                    yield Label("Memory limit (GB)")
                    yield Input(value="50", id="mem-limit")
                with Vertical(classes="field"):
                    yield Label("Additional tags")
                    yield Input(placeholder="tag1,tag2,...", id="extra-tags")
                with Vertical(classes="field"):
                    yield Label("Additional labels")
                    yield Input(placeholder="key=val,key2=val2,...", id="extra-labels")
            with Vertical(id="right-col"):
                with Horizontal(id="toggles"):
                    yield Checkbox("Push", id="push", value=False)
                    yield Checkbox("Dry run", id="dry-run", value=False)
                    yield Checkbox("Tests", id="tests", value=False)
                    yield Checkbox("Slim image", id="slim", value=False)
        yield Button("Build", id="build-btn", variant="primary")
        yield Footer()

    def action_go_back(self) -> None:
        self.app.pop_screen()

    def on_button_pressed(self, event: Button.Pressed) -> None:
        if event.button.id == "build-btn":
            self._start_build()

    def _start_build(self) -> None:
        build_config = {
            **self.config,
            "nproc": self.query_one("#nproc", Input).value,
            "mem_limit": self.query_one("#mem-limit", Input).value,
            "push": self.query_one("#push", Checkbox).value,
            "dry_run": self.query_one("#dry-run", Checkbox).value,
            "tests": self.query_one("#tests", Checkbox).value,
            "slim": self.query_one("#slim", Checkbox).value,
            "extra_tags": self.query_one("#extra-tags", Input).value,
            "extra_labels": self.query_one("#extra-labels", Input).value,
        }
        from tui.screens.build import BuildScreen
        self.app.push_screen(BuildScreen(build_config))
