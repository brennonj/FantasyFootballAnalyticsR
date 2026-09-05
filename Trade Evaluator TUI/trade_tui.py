#!/usr/bin/env python3
"""SSH-friendly terminal view of the trade evaluator.

Reads Data/trade_snapshot.json, written by R Scripts/Trade Tool/trade_snapshot.R
(pending-trade verdicts every 5 min, full-league recommendations every 30 min -
see that file for why the two run on different cadences). This process has no
ESPN session and no R dependency of its own - it only ever reads that file, so
it's safe to run over SSH without holding any credentials.

Run ./trade-evaluator-tui.sh from the project root; it starts the snapshot
poller and this app together. To run this file directly instead:

    Trade\\ Evaluator\\ TUI/.venv/bin/python "Trade Evaluator TUI/trade_tui.py" \\
        [path/to/trade_snapshot.json]
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
VERDICT_STYLE = {"ACCEPT": GOOD, "DECLINE": CRIT, "MARGINAL": WARN}

DEFAULT_SNAPSHOT = Path(__file__).resolve().parent.parent / "Data" / "trade_snapshot.json"


def pos_badge(pos: str) -> Text:
    base = pos.split("/")[0]
    return Text(f" {pos} ", style=f"bold white on {POS_COLORS.get(base, MUTED)}")


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

        line = Text("TRADE EVALUATOR  ", style="bold")
        line.append(team + "   ", style=MUTED)
        line.append_text(status)
        return line


class Pending(Static):
    items = reactive(list)

    def render(self):
        if not self.items:
            return Panel(Text("No pending trades involve you right now.", style=MUTED),
                        title="Pending trades involving you")
        grid = Table.grid(expand=True, padding=(0, 1))
        grid.add_column(width=9)
        grid.add_column(ratio=1)
        grid.add_column(justify="right", width=7)
        for r in self.items:
            body = Text.assemble(
                ("Receive: ", MUTED), (r["receive_players"], "white"), (" -> ", MUTED),
                ("Give: ", MUTED), (r["give_players"], "white"), "\n",
                (f"vs {r['opponent']} · season {r['my_long_gain']:+.1f} VOR · "
                 f"this week {r['my_short_gain']:+.1f}", MUTED),
            )
            score_style = GOOD if r["my_score"] > 0 else CRIT
            grid.add_row(Text(r["verdict"], style=f"bold {VERDICT_STYLE.get(r['verdict'], MUTED)}"),
                        body, Text(f"{r['my_score']:+.1f}", style=f"bold {score_style}"))
        return Panel(grid, title="Pending trades involving you")


class Recommendations(Static):
    items = reactive(list)

    def render(self):
        if not self.items:
            return Panel(Text("No 1-for-1 trade improves both sides right now "
                              "(recomputed every 30 min).", style=MUTED),
                        title="Trade recommendations")
        grid = Table.grid(expand=True, padding=(0, 1))
        grid.add_column(width=4)
        grid.add_column(ratio=1)
        grid.add_column(justify="right", width=6)
        for r in self.items:
            body = Text.assemble(
                ("Give: ", MUTED), (r["give_player"], "white"), (" -> ", MUTED),
                ("Get: ", MUTED), (f"{r['receive_player']} ({r['opponent']})", "white"), "\n",
                (r["why"], MUTED),
            )
            grid.add_row(pos_badge(r["give_pos"]), body, Text(f"+{r['my_gain']:.1f}", style=f"bold {GOOD}"))
        return Panel(grid, title="Trade recommendations (every 30 min)")


class TradeApp(App):
    CSS = """
    Screen { background: #0d0d0d; }
    #topbar { height: 1; padding: 0 1; background: #1a1a19; }
    #main { height: 1fr; padding: 0 1; }
    Pending, Recommendations { height: auto; margin-bottom: 1; }
    """

    BINDINGS = [("q", "quit", "Quit")]

    def __init__(self, snapshot_path: Path):
        super().__init__()
        self.snapshot_path = snapshot_path
        self._mtime = None
        self._data = None

    def compose(self) -> ComposeResult:
        yield SyncStatus(id="topbar")
        with VerticalScroll(id="main"):
            yield Pending()
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
            self.query_one(Pending).items = data.get("pending") or []
            self.query_one(Recommendations).items = data.get("recommendations") or []
        self.query_one(SyncStatus).data = self._data


def main():
    snapshot_path = Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_SNAPSHOT
    TradeApp(snapshot_path).run()


if __name__ == "__main__":
    main()
