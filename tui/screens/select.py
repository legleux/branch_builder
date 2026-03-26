"""Fork/branch/PR selection screen."""

from textual import work
from textual.app import ComposeResult
from textual.screen import Screen
from textual.widgets import (
    DataTable,
    Footer,
    Header,
    Input,
    Static,
    TabbedContent,
    TabPane,
    Tree,
)

from tui.github import is_ripple_member, list_branches, list_forks, list_prs


class SelectScreen(Screen):
    BINDINGS = [
        ("escape", "app.quit", "Quit"),
    ]

    CSS = """
    Tree {
        height: 1fr;
    }
    DataTable {
        height: 1fr;
    }
    #status {
        dock: bottom;
        height: 1;
        background: $surface;
        color: $text-muted;
        padding: 0 1;
    }
    """

    def __init__(self):
        super().__init__()
        self._forks: list[dict] = []
        self._prs: list[dict] = []
        self._prs_loaded = False
        self._forks_loaded = False
        self._branches_cache: dict[str, list[str]] = {}

    def compose(self) -> ComposeResult:
        yield Header(show_clock=True)
        with TabbedContent("PRs", "Branches", "Forks"):
            with TabPane("PRs", id="prs-tab"):
                yield Input(placeholder="Filter by #, title, author, branch...", id="filter-prs")
                yield DataTable(id="prs-table")
            with TabPane("Branches", id="branches-tab"):
                yield Input(placeholder="Filter branches...", id="filter-branches")
                yield Tree("XRPLF/rippled", id="branches-tree")
            with TabPane("Forks", id="forks-tab"):
                yield Input(placeholder="Filter forks...", id="filter-forks")
                yield Tree("Forks", id="forks-tree")
        yield Static("", id="status")
        yield Footer()

    def on_mount(self) -> None:
        self._update_status("Loading PRs and forks...")

        prs_table = self.query_one("#prs-table", DataTable)
        prs_table.add_columns("#", "Title", "Author", "Branch")
        prs_table.cursor_type = "row"
        prs_table.loading = True

        self.load_prs()
        self.load_base_branches()
        self.load_forks()

    def _update_status(self, msg: str) -> None:
        self.query_one("#status", Static).update(msg)

    # --- PRs ---

    @work(thread=True)
    def load_prs(self) -> None:
        self._prs = list_prs()
        self._prs_loaded = True
        self.app.call_from_thread(self._on_prs_loaded)

    def _on_prs_loaded(self) -> None:
        self.query_one("#prs-table", DataTable).loading = False
        self._populate_prs()
        self._update_status(f"{len(self._prs)} open PRs")

    MAX_VISIBLE = 30

    def _populate_prs(self, filter_text: str = "") -> None:
        table = self.query_one("#prs-table", DataTable)
        table.clear()
        if not self._prs_loaded:
            return
        matches = [
            pr for pr in self._prs
            if not filter_text
                or filter_text.lower() in pr.get("title", "").lower()
                or filter_text.lower() in pr.get("headRefName", "").lower()
                or filter_text.lower() in pr.get("author", {}).get("login", "").lower()
                or filter_text in str(pr.get("number", ""))
        ]
        for pr in matches[:self.MAX_VISIBLE]:
            author = pr.get("author", {}).get("login", "?")
            author_display = f"[orange1]{author}[/]" if not is_ripple_member(author) else author
            table.add_row(
                str(pr["number"]),
                pr.get("title", "")[:60],
                author_display,
                pr.get("headRefName", "?"),
                key=str(pr["number"]),
            )
        if len(matches) > self.MAX_VISIBLE:
            self._update_status(f"Showing {self.MAX_VISIBLE} of {len(matches)} PRs")
        else:
            self._update_status(f"{len(matches)} PRs")

    # --- Branches (base repo, tree by branch) ---

    @work(thread=True)
    def load_base_branches(self) -> None:
        branches = list_branches("XRPLF")
        self._branches_cache["XRPLF"] = branches
        self.app.call_from_thread(self._populate_branches_tree, branches)

    def _populate_branches_tree(self, branches: list[str], filter_text: str = "") -> None:
        tree = self.query_one("#branches-tree", Tree)
        tree.clear()
        # Group branches by first path segment (e.g. "ripple/smart-escrow" -> "ripple")
        groups: dict[str, list[str]] = {}
        top_level: list[str] = []
        for branch in branches:
            if filter_text and filter_text.lower() not in branch.lower():
                continue
            if "/" in branch:
                prefix = branch.split("/")[0]
                groups.setdefault(prefix, []).append(branch)
            else:
                top_level.append(branch)
        tree.root.expand()
        for branch in top_level:
            tree.root.add_leaf(branch, data={"owner": "XRPLF", "branch": branch})
        for prefix, group_branches in sorted(groups.items()):
            node = tree.root.add(f"{prefix}/ ({len(group_branches)})")
            for branch in group_branches:
                node.add_leaf(branch, data={"owner": "XRPLF", "branch": branch})
        self._update_status(f"{len(branches)} branches")

    # --- Forks (tree grouped by owner) ---

    @work(thread=True)
    def load_forks(self) -> None:
        self._forks = list_forks()
        self._forks_loaded = True
        self.app.call_from_thread(self._populate_forks_tree)

    def _populate_forks_tree(self, filter_text: str = "") -> None:
        tree = self.query_one("#forks-tree", Tree)
        tree.clear()
        tree.root.expand()
        matches = [
            f for f in self._forks
            if not filter_text or filter_text.lower() in f["owner"].lower()
        ]
        for fork in matches[:self.MAX_VISIBLE]:
            owner = fork["owner"]
            label = f"[orange1]{owner}[/]" if not is_ripple_member(owner) else owner
            tree.root.add(label, data={"owner": owner})
        if len(matches) > self.MAX_VISIBLE:
            self._update_status(
                f"Showing {self.MAX_VISIBLE} of {len(matches)} forks — type to filter"
            )
        elif self._forks_loaded:
            self._update_status(f"{len(matches)} forks")

    @work(thread=True)
    def _load_fork_branches(self, owner: str, node) -> None:
        if owner in self._branches_cache:
            branches = self._branches_cache[owner]
        else:
            branches = list_branches(owner)
            self._branches_cache[owner] = branches
        self.app.call_from_thread(self._add_branches_to_node, node, owner, branches)

    def _add_branches_to_node(self, node, owner: str, branches: list[str]) -> None:
        node.remove_children()
        for branch in branches:
            node.add_leaf(branch, data={"owner": owner, "branch": branch})
        node.expand()
        self._update_status(f"{len(branches)} branches for {owner}")

    # --- Events ---

    def on_tree_node_selected(self, event: Tree.NodeSelected) -> None:
        data = event.node.data
        if not data:
            return

        if "branch" in data:
            from tui.screens.options import OptionsScreen
            self.app.push_screen(
                OptionsScreen({"owner": data["owner"], "branch": data["branch"]})
            )
        elif "owner" in data:
            owner = data["owner"]
            if not event.node.children:
                event.node.add_leaf("Loading...")
                self._load_fork_branches(owner, event.node)
            else:
                event.node.toggle()

    def on_data_table_row_selected(self, event: DataTable.RowSelected) -> None:
        if event.data_table.id == "prs-table":
            pr_num = str(event.row_key.value)
            pr = next((p for p in self._prs if str(p["number"]) == pr_num), None)
            if pr:
                owner = pr.get("headRepositoryOwner", {}).get("login", "")
                branch = pr.get("headRefName", "")
                from tui.screens.options import OptionsScreen
                self.app.push_screen(
                    OptionsScreen({"owner": owner, "branch": branch, "pr": pr_num})
                )

    def on_input_changed(self, event: Input.Changed) -> None:
        if event.input.id == "filter-prs":
            self._populate_prs(event.value)
        elif event.input.id == "filter-forks":
            self._populate_forks_tree(event.value)
        elif event.input.id == "filter-branches":
            branches = self._branches_cache.get("XRPLF", [])
            self._populate_branches_tree(branches, event.value)
