#!/usr/bin/env python3
"""SSH-friendly terminal view of the weekly lineup optimizer.

Reads Data/lineup_snapshot.json, written every 5 minutes by
R Scripts/Lineup Tool/lineup_snapshot.R (which shares its optimal-lineup
logic with the Shiny web app). This process has no ESPN session and no R
dependency of its own - it only ever reads that file, so it's safe to run
over SSH without holding any credentials.

Run ./lineup-optimizer-tui.sh from the project root; it starts the snapshot
poller and this app together. To run this file directly instead:

    Lineup\\ Optimizer\\ TUI/.venv/bin/python "Lineup Optimizer TUI/lineup_tui.py" \\
        [path/to/lineup_snapshot.json]
"""

import io
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

from rich.console import Console
from rich.panel import Panel
from rich.table import Table
from rich.text import Text
from textual.app import App, ComposeResult
from textual.containers import Horizontal, VerticalScroll
from textual.reactive import reactive
from textual.widgets import Footer, Static

# See the identical note in Draft Board TUI/draft_board_tui.py: Textual's own
# auto-height sizing caches height keyed only by width, so a panel that
# starts empty and later fills with data can get stuck clipped at its first
# (1-line) size. Measuring with a throwaway Rich Console sidesteps that.
_MEASURE_CONSOLE = Console(file=io.StringIO(), width=200, legacy_windows=False)


def measured_height(renderable, width: int) -> int:
    options = _MEASURE_CONSOLE.options.update(width=max(width, 1))
    return len(_MEASURE_CONSOLE.render_lines(renderable, options, pad=False))


class AutoHeightStatic(Static):
    def get_content_height(self, container, viewport, width: int) -> int:
        return measured_height(self.render(), width)


POS_COLORS = {
    "QB": "#3987e5", "RB": "#d95926", "WR": "#199e70",
    "TE": "#c98500", "K": "#d55181", "DST": "#008300",
}
GOOD, WARN, CRIT, MUTED = "#0ca30c", "#fab219", "#d03b3b", "#898781"
NEEDS_ATTENTION = {"QUESTIONABLE", "DOUBTFUL", "OUT", "IR"}

DEFAULT_SNAPSHOT = Path(__file__).resolve().parent.parent / "Data" / "lineup_snapshot.json"


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

        line = Text("WEEKLY LINEUP OPTIMIZER  ", style="bold")
        line.append(team + "   ", style=MUTED)
        line.append_text(status)
        return line


class Tiles(AutoHeightStatic):
    data = reactive(None, layout=True)

    def render(self):
        d = self.data
        t = d.get("tiles") if d else None
        table = Table.grid(expand=True, padding=(0, 2))
        for _ in range(3):
            table.add_column(ratio=1)
        if not t:
            table.add_row("—", "—", "—")
            return Panel(table, border_style=MUTED)
        gain = t["gain"]
        gain_style = GOOD if gain > 0 else MUTED
        table.add_row(
            Text.assemble(("Optimal points\n", MUTED), (f"{t['optimal_points']:.1f}", "bold")),
            Text.assemble(("Current lineup\n", MUTED), (f"{t['current_points']:.1f}", "bold")),
            Text.assemble(("Gain from swaps\n", MUTED),
                           (f"{'+' if gain > 0 else ''}{gain:.1f}", f"bold {gain_style}")),
        )
        return Panel(table, border_style=MUTED)


class Flags(AutoHeightStatic):
    flags = reactive(list, layout=True)

    def render(self):
        if not self.flags:
            return Text("")
        out = Text()
        for f in self.flags:
            style = CRIT if f["note"].split(" ")[0] in NEEDS_ATTENTION else WARN
            out.append(f"! {f['player']} ({f['pos']}) - {f['note']}\n", style=style)
        return out


class Swaps(AutoHeightStatic):
    swaps = reactive(list, layout=True)

    def render(self):
        if not self.swaps:
            return Panel(Text("Your current lineup is already optimal.", style=MUTED),
                        title="Recommended swaps")
        grid = Table.grid(expand=True, padding=(0, 1))
        grid.add_column(width=10)
        grid.add_column(ratio=1)
        grid.add_column(justify="right", width=6)
        for s in self.swaps:
            bench = s.get("bench_player") or "(empty)"
            grid.add_row(pos_badge(s["slot"]),
                         Text.assemble((f"{bench} ", MUTED), ("-> ", MUTED),
                                       (s["start_player"], "white")),
                         Text(f"+{s['gain']:.1f}", style=f"bold {GOOD}"))
        return Panel(grid, title="Recommended swaps")


class PlayerList(AutoHeightStatic):
    """Renders either the starters or bench list - identical shape, so one
    widget class serves both (title and data differ per instance)."""
    rows = reactive(list, layout=True)

    def __init__(self, title: str, **kwargs):
        super().__init__(**kwargs)
        self.title = title

    def render(self):
        grid = Table.grid(expand=True, padding=(0, 1))
        grid.add_column(width=10)
        grid.add_column(ratio=1)
        grid.add_column(justify="right", width=6)
        if not self.rows:
            grid.add_row("—", "", "")
        for r in self.rows:
            name = Text(r["player"], style="white")
            if r["injury_status"] != "ACTIVE":
                name.append(f"  {r['injury_status']}", style=WARN)
            grid.add_row(pos_badge(r["pos"]), name, Text(f"{r['points']:.1f}"))
        return Panel(grid, title=self.title)


class LineupApp(App):
    CSS = """
    Screen { background: #0d0d0d; }
    #topbar { height: 1; padding: 0 1; background: #1a1a19; }
    #tiles { height: auto; padding: 0 1; }
    Flags { height: auto; padding: 0 1; }
    #main { height: 1fr; }
    #left { width: 50%; padding: 0 1; }
    #right { width: 50%; padding: 0 1; }
    Swaps, PlayerList { height: auto; margin-bottom: 1; }
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
        yield Flags()
        with Horizontal(id="main"):
            with VerticalScroll(id="left"):
                yield Swaps()
                yield PlayerList("Optimal starters", id="starters")
            with VerticalScroll(id="right"):
                yield PlayerList("Bench", id="bench")
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
                return  # mid-write; the poller writes atomically, try again next tick
            self._data = data
            self.query_one(Tiles).data = data
            self.query_one(Flags).flags = data.get("flags") or []
            self.query_one(Swaps).swaps = data.get("swaps") or []
            self.query_one("#starters", PlayerList).rows = data.get("starters") or []
            self.query_one("#bench", PlayerList).rows = data.get("bench") or []
        self.query_one(SyncStatus).data = self._data


def main():
    snapshot_path = Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_SNAPSHOT
    LineupApp(snapshot_path).run()


if __name__ == "__main__":
    main()
