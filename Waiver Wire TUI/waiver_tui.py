#!/usr/bin/env python3
"""SSH-friendly terminal view of waiver-wire add/drop recommendations.

Reads Data/waiver_snapshot.json, written every 5 minutes by
R Scripts/Waiver Tool/waiver_snapshot.R (which shares its recommendation
logic with the Shiny web app). This process has no ESPN session and no R
dependency of its own - it only ever reads that file, so it's safe to run
over SSH without holding any credentials.

Run ./waiver-wire-tui.sh from the project root; it starts the snapshot
poller and this app together. To run this file directly instead:

    Waiver\\ Wire\\ TUI/.venv/bin/python "Waiver Wire TUI/waiver_tui.py" \\
        [path/to/waiver_snapshot.json]
"""

import json
import sys
from datetime import datetime, timezone
from pathlib import Path

from rich.panel import Panel
from rich.table import Table
from rich.text import Text
from textual.app import App, ComposeResult
from textual.containers import VerticalScroll
from textual.reactive import reactive
from textual.widgets import Footer, Static

POS_COLORS = {
    "QB": "#3987e5", "RB": "#d95926", "WR": "#199e70",
    "TE": "#c98500", "K": "#d55181", "DST": "#008300",
}
GOOD, WARN, CRIT, MUTED = "#0ca30c", "#fab219", "#d03b3b", "#898781"

DEFAULT_SNAPSHOT = Path(__file__).resolve().parent.parent / "Data" / "waiver_snapshot.json"


def pos_badge(pos: str) -> Text:
    return Text(f" {pos} ", style=f"bold white on {POS_COLORS.get(pos, MUTED)}")


def parse_ts(s):
    if not s:
        return None
    return datetime.strptime(s, "%Y-%m-%dT%H:%M:%S%z")


class SyncStatus(Static):
    data = reactive(None)

    def render(self):
        d = self.data
        if d is None:
            return Text("waiting for snapshot...", style=MUTED)
        last_sync = parse_ts(d.get("last_sync"))
        failed = bool(d.get("sync_failed"))
        team = f"{d.get('team_name', '')} · week {d.get('week', '?')} · {d.get('season', '')}"

        if last_sync is None:
            status = Text("● ", style=CRIT if failed else WARN)
            status.append("cannot reach ESPN" if failed else "connecting")
        elif failed:
            mins = int((datetime.now(timezone.utc) - last_sync).total_seconds() // 60)
            status = Text("● ", style=CRIT)
            status.append(f"STALE - no sync for {mins} min (last {last_sync:%H:%M:%S})")
        else:
            status = Text("● ", style=GOOD)
            status.append(f"synced {last_sync:%H:%M:%S}")

        line = Text("WAIVER WIRE  ", style="bold")
        line.append(team + "   ", style=MUTED)
        line.append_text(status)
        return line


class Tiles(Static):
    data = reactive(None)

    def render(self):
        d = self.data
        table = Table.grid(expand=True, padding=(0, 2))
        for _ in range(3):
            table.add_column(ratio=1)
        if not d:
            table.add_row("—", "—", "—")
            return Panel(table, border_style=MUTED)
        table.add_row(
            Text.assemble(("Free agents scanned\n", MUTED), (str(d.get("pool_size", "—")), "bold")),
            Text.assemble(("Your roster\n", MUTED), (str(d.get("roster_size", "—")), "bold")),
            Text.assemble(("Worthwhile adds\n", MUTED),
                           (str(len(d.get("recommendations") or [])), "bold")),
        )
        return Panel(table, border_style=MUTED)


class Recommendations(Static):
    recs = reactive(list)

    def render(self):
        if not self.recs:
            return Panel(Text("No free agent beats your worst rostered player right now.", style=MUTED),
                        title="Recommended adds")
        grid = Table.grid(expand=True, padding=(0, 1))
        grid.add_column(width=4)
        grid.add_column(ratio=1)
        grid.add_column(justify="right", width=6)
        for r in self.recs:
            name = Text.assemble(
                (r["player"] + " ", "bold white"), ("-> drop ", MUTED), (r["drop_player"], "white"),
            )
            why = Text(r["why"], style=MUTED)
            grid.add_row(pos_badge(r["pos"]), Text.assemble(name, "\n", why), Text(f"+{r['score']}", style=f"bold {GOOD}"))
        return Panel(grid, title="Recommended adds")


class WaiverApp(App):
    CSS = """
    Screen { background: #0d0d0d; }
    #topbar { height: 1; padding: 0 1; background: #1a1a19; }
    #tiles { height: auto; padding: 0 1; }
    #main { height: 1fr; padding: 0 1; }
    Recommendations { height: auto; }
    """

    BINDINGS = [("q", "quit", "Quit")]

    def __init__(self, snapshot_path: Path):
        super().__init__()
        self.snapshot_path = snapshot_path
        self._mtime = None
        self._data = None

    def compose(self) -> ComposeResult:
        yield SyncStatus(id="topbar")
        yield Tiles(id="tiles")
        with VerticalScroll(id="main"):
            yield Recommendations()
        yield Footer()

    def on_mount(self):
        self.set_interval(2.0, self.poll_snapshot)
        self.poll_snapshot()

    def poll_snapshot(self):
        try:
            mtime = self.snapshot_path.stat().st_mtime
        except FileNotFoundError:
            self.query_one(SyncStatus).data = None
            return
        if mtime != self._mtime:
            self._mtime = mtime
            try:
                data = json.loads(self.snapshot_path.read_text())
            except (json.JSONDecodeError, OSError):
                return
            self._data = data
            self.query_one(Tiles).data = data
            self.query_one(Recommendations).recs = data.get("recommendations") or []
        self.query_one(SyncStatus).data = self._data


def main():
    snapshot_path = Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_SNAPSHOT
    WaiverApp(snapshot_path).run()


if __name__ == "__main__":
    main()
