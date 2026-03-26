"""Branch Builder TUI app."""

from textual.app import App

from tui.github import check_auth
from tui.screens.select import SelectScreen


class BranchBuilderApp(App):
    TITLE = "Branch Builder"
    SUB_TITLE = "Build xrpld Docker images from any fork/branch"

    def on_mount(self) -> None:
        if not check_auth():
            self.notify(
                "Not authenticated. Run: gh auth login",
                severity="error",
                timeout=5,
            )
            self.exit()
            return
        self.push_screen(SelectScreen())
