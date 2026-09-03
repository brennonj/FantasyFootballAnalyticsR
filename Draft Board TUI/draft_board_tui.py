#!/usr/bin/env python3
"""SSH-friendly terminal view of the live ESPN draft board.

Reads Data/draft_board_snapshot.json, written every 15s by
R Scripts/Draft Tool/draft_board_snapshot.R (which shares its VOR/VONA
recommendation logic with the Shiny web board). This process has no ESPN
session and no R dependency of its own - it only ever reads that file, so
it's safe to run over SSH without holding any credentials.

Run ./draft-board-tui.sh from the project root; it starts the snapshot
poller and this app together. To run this file directly instead:

    Draft\\ Board\\ TUI/.venv/bin/python "Draft Board TUI/draft_board_tui.py" \\
        [path/to/draft_board_snapshot.json]
"""

import io
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

from rich.console import Console, Group
from rich.panel import Panel
from rich.table import Table
from rich.text import Text
from textual.app import App, ComposeResult
from textual.containers import Horizontal, VerticalScroll
from textual.reactive import reactive
from textual.widgets import DataTable, Footer, Static

# Textual's own auto-height sizing (Widget.get_content_height) caches the
# computed height keyed ONLY by width, not by content. Each of our panels
# renders once (as an empty "-" placeholder) before its first snapshot poll
# arrives, caching a 1-line height at the current width; when real data then
# fills in 3+ rows, that stale cache is never invalidated (the width hasn't
# changed) and the panel stays clipped to its very first size. Confirmed on
# an iPad SSH client (Blink Shell) even though it never reproduced locally in
# tmux, where test harnesses happened to already have data loaded before the
# first render. Measuring height ourselves with a throwaway Rich Console -
# instead of relying on Widget.get_content_height's cached measurement -
# sidesteps that cache entirely.
_MEASURE_CONSOLE = Console(file=io.StringIO(), width=200, legacy_windows=False)


def measured_height(renderable, width: int) -> int:
    options = _MEASURE_CONSOLE.options.update(width=max(width, 1))
    return len(_MEASURE_CONSOLE.render_lines(renderable, options, pad=False))


class AutoHeightStatic(Static):
    """A Static whose CSS `height: auto` is sized exactly, every time, from
    its own render() output - see the cache-bug note above."""

    def get_content_height(self, container, viewport, width: int) -> int:
        return measured_height(self.render(), width)

POS_COLORS = {
    "QB": "#3987e5", "RB": "#d95926", "WR": "#199e70",
    "TE": "#c98500", "K": "#d55181", "DST": "#008300",
}
POS_ORDER = ["All", "QB", "RB", "WR", "TE", "K", "DST"]
MAX_ALTERNATIVES = 3  # each row wraps to 2-3 terminal lines; more than this
                       # routinely gets pushed below the fold in a normal-height
                       # terminal, with no obvious way to scroll down to see it
GOOD, WARN, CRIT, MUTED = "#0ca30c", "#fab219", "#d03b3b", "#898781"

DEFAULT_SNAPSHOT = Path(__file__).resolve().parent.parent / "Data" / "draft_board_snapshot.json"


def pos_badge(pos: str) -> Text:
    return Text(f" {pos} ", style=f"bold white on {POS_COLORS.get(pos, MUTED)}")


def parse_ts(s):
    if not s:
        return None
    return datetime.strptime(s, "%Y-%m-%dT%H:%M:%S%z")


class SyncStatus(Static):
    """Mirrors the Shiny app's livedot: ticks between polls even when the
    underlying snapshot hasn't changed, so a stale feed is visibly stale."""

    data = reactive(None)

    def render(self):
        d = self.data
        if d is None:
            return Text("waiting for snapshot...", style=MUTED)
        last_sync = parse_ts(d.get("last_sync"))
        failed = bool(d.get("sync_failed"))
        team = f"{d.get('team_name', '')} · {d.get('season', '')} · full PPR"

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

        line = Text("BRENNON'S DRAFT COMMAND CENTER  ", style="bold")
        line.append(team + "   ", style=MUTED)
        line.append_text(status)
        return line


class Notices(AutoHeightStatic):
    # layout=True: without it, updating this reactive repaints in place but
    # never re-runs the "auto" height calc, so the widget stays frozen at
    # whatever size it had when first mounted (empty) - see the module-level
    # note by AutoHeightStatic.
    notices = reactive(list, layout=True)

    def render(self):
        if not self.notices:
            return Text("")
        out = Text()
        for n in self.notices:
            out.append("! " + n["title"] + "\n", style=f"bold {WARN}")
            out.append(n["detail"] + "\n\n", style=MUTED)
        return out


class Hero(AutoHeightStatic):
    data = reactive(None, layout=True)

    def render(self):
        d = self.data
        if d is None:
            return Panel(Text("Waiting for ESPN draft feed", style=MUTED), border_style=MUTED)
        if d.get("complete"):
            return Panel(Text("Draft complete", style=MUTED), border_style=MUTED)
        oc = d.get("on_clock")
        hero = d.get("hero")
        if oc is None or hero is None:
            return Panel(Text("No players available", style=MUTED), border_style=MUTED)

        head = Text(
            f"On the clock · {oc['franchise_name']} · round {oc['round']}, pick {oc['overall']}"
            + ("  · YOUR PICK" if oc["mine"] else ""),
            style=f"bold {WARN}" if oc["mine"] else MUTED,
        )
        name = Text(hero["player"], style="bold white")
        sub = Text()
        sub.append_text(pos_badge(hero["pos"]))
        sub.append(f"  {hero['team']}   VOR {hero['points_vor']:.0f}   VONA {hero['vona']:.1f}")
        chips = Text(" · ".join(hero.get("why", [])), style=MUTED)

        body = Table.grid(padding=(0, 0))
        body.add_row(head)
        body.add_row(name)
        body.add_row(sub)
        body.add_row(chips)
        return Panel(body, border_style="#3987e5", title="Hero pick")


class Tiles(AutoHeightStatic):
    data = reactive(None, layout=True)

    def render(self):
        d = self.data
        t = d.get("tiles") if d else None
        table = Table.grid(expand=True, padding=(0, 2))
        for _ in range(4):
            table.add_column(ratio=1)
        if not t:
            table.add_row("—", "—", "—", "—")
            return Panel(table, border_style=MUTED)

        away = t["picks_away"]
        away_txt = "—" if away is None else ("NOW" if away == 0 else str(away))
        table.add_row(
            Text.assemble(("Your next pick\n", MUTED), (away_txt, "bold")),
            Text.assemble(("Starters filled\n", MUTED),
                           (f"{t['starters_have']}/{t['starters_needed']}", "bold")),
            Text.assemble(("Players left\n", MUTED), (str(t["players_left"]), "bold")),
            Text.assemble(("Top VONA on board\n", MUTED),
                           ("—" if t["top_vona"] is None else f"{t['top_vona']:.1f}", "bold")),
        )
        return Panel(table, border_style=MUTED)


class Targets(AutoHeightStatic):
    data = reactive(None, layout=True)

    def render(self):
        d = self.data
        if not d:
            return Panel(Text("—", style=MUTED), title="Your next pick · likely available")
        pick = d.get("my_target_pick")
        oc = d.get("on_clock")
        targets = d.get("my_targets") or []
        if d.get("complete") or pick is None or oc is None:
            body = Text("No further picks" if pick is None else "—", style=MUTED)
        elif not targets:
            body = Text("No likely targets", style=MUTED)
        else:
            away = pick - oc["overall"]
            grid = Table.grid(expand=True, padding=(0, 1))
            grid.add_column(width=4)
            grid.add_column(ratio=1)
            grid.add_column(justify="right", width=6)
            for a in targets:
                sub = " · ".join([f"VOR {a['points_vor']:.0f}"] + a.get("why", []))
                grid.add_row(pos_badge(a["pos"]),
                             Text.assemble((a["player"] + "\n", "white"), (sub, MUTED)),
                             Text(f"{a['avail_pct']}%", style=f"bold {GOOD}"))
            body = Group(Text(f"Pick {pick} · {away} picks away", style=MUTED), grid)
        return Panel(body, border_style=GOOD, title="Your next pick · likely available")


class Alternatives(AutoHeightStatic):
    data = reactive(None, layout=True)

    def render(self):
        d = self.data
        alts = ((d.get("alternatives") or []) if d else [])[:MAX_ALTERNATIVES]
        if not alts:
            return Panel(Text("—", style=MUTED), title="Next best alternatives")
        # One line per row on purpose (no wrapped "why" text like Hero/Targets
        # get) - this is what keeps 2-3 of these reliably on screen without
        # scrolling; the full reasoning for whoever's on the clock is already
        # in the hero panel above.
        body = Table.grid(expand=True, padding=(0, 1))
        body.add_column(width=4)
        body.add_column(ratio=1)
        body.add_column(justify="right", width=6)
        for a in alts:
            body.add_row(pos_badge(a["pos"]),
                         Text(a["player"], style="white", overflow="ellipsis", no_wrap=True),
                         Text(f"{a['score']:.1f}"))
        return Panel(body, title="Next best alternatives")


class Scarcity(AutoHeightStatic):
    data = reactive(None, layout=True)

    def render(self):
        d = self.data
        counts = (d.get("scarcity") or {}) if d else {}
        body = Table.grid(expand=True, padding=(0, 1))
        body.add_column(width=4)
        body.add_column(ratio=1)
        body.add_column(width=14, justify="right")
        max_n = max(list(counts.values()) + [1])
        for p in POS_ORDER[1:]:
            n = counts.get(p, 0)
            bar_len = 20
            filled = round(bar_len * n / max_n) if max_n else 0
            bar = Text("█" * filled, style=POS_COLORS[p]) + Text("░" * (bar_len - filled), style="grey23")
            body.add_row(Text(p, style="bold"), bar, Text(f"{n} above repl.", style=MUTED))
        return Panel(body, title="Positional scarcity")


class Roster(AutoHeightStatic):
    data = reactive(None, layout=True)

    def render(self):
        d = self.data
        if not d:
            return Panel(Text("—", style=MUTED), title="Your roster")
        roster = d.get("roster") or {}
        slots = d.get("slots") or {}
        mine = roster.get("mine") or []
        filled = roster.get("filled") or {}

        body = Table.grid(expand=True, padding=(0, 1))
        body.add_column(width=4)
        body.add_column(ratio=1)
        body.add_column(justify="right", width=6)
        if not mine:
            body.add_row(Text("No picks yet", style=MUTED), "", "")
        for m in mine:
            body.add_row(pos_badge(m["pos"]), m["player"], Text(f"R{m['round']}"))
        body.add_row(Text())
        for p, need in slots.items():
            have = filled.get(p, 0)
            ok = have >= need
            col = GOOD if ok else WARN
            body.add_row(pos_badge(p), f"{have} of {need} starters",
                         Text("ok" if ok else f"-{need - have}", style=col))
        return Panel(body, title="Your roster")


class BoardTable(DataTable):
    """Available-players table. Owns its own filter state so toggling
    position/hide-drafted doesn't require a fresh JSON read."""

    board = reactive(list, always_update=True)
    pos_filter = reactive("All")
    hide_drafted = reactive(True)

    def on_mount(self):
        self.cursor_type = "row"
        self.add_columns("Player", "Pos", "Tm", "Pts", "VOR", "ADP", "Avail %", "Tier")

    def watch_board(self, *_):
        self._redraw()

    def watch_pos_filter(self, *_):
        self._redraw()

    def watch_hide_drafted(self, *_):
        self._redraw()

    def _redraw(self):
        self.clear()
        rows = self.board
        if self.hide_drafted:
            rows = [r for r in rows if not r.get("drafted")]
        if self.pos_filter != "All":
            rows = [r for r in rows if r["pos"] == self.pos_filter]
        for r in rows:
            avail = "—" if r.get("avail_pct") is None else f"{r['avail_pct']:.0f}"
            self.add_row(
                r["player"], pos_badge(r["pos"]), r["team"],
                f"{r['points']:.1f}", f"{r['points_vor']:.1f}",
                f"{r['adp_avg']:.1f}", avail, str(r.get("tier", "—")),
            )


class DraftBoardApp(App):
    CSS = """
    Screen { background: #0d0d0d; }
    #topbar { height: 1; padding: 0 1; background: #1a1a19; }
    Notices { height: auto; padding: 0 1; }
    #hero { height: auto; padding: 0 1; }
    #tiles { height: auto; padding: 0 1; }
    #main { height: 1fr; }
    #left { width: 62%; padding: 0 1; }
    #right { width: 38%; padding: 0 1; }
    #controls { height: 1; color: #898781; padding: 0 1; }
    BoardTable { height: 1fr; }
    Targets, Alternatives, Scarcity, Roster { height: auto; margin-bottom: 1; }
    """

    BINDINGS = [
        ("q", "quit", "Quit"),
        ("p", "cycle_filter", "Cycle position"),
        ("h", "toggle_hide", "Toggle hide drafted"),
    ]

    def __init__(self, snapshot_path: Path):
        super().__init__()
        self.snapshot_path = snapshot_path
        self._mtime = None

    def compose(self) -> ComposeResult:
        yield SyncStatus(id="topbar")
        yield Notices()
        yield Hero(id="hero")
        yield Tiles(id="tiles")
        with Horizontal(id="main"):
            with VerticalScroll(id="left"):
                yield Static(id="controls")
                yield BoardTable()
            with VerticalScroll(id="right"):
                yield Targets()
                yield Alternatives()
                yield Scarcity()
                yield Roster()
        yield Footer()

    def on_mount(self):
        self._update_controls()
        self.set_interval(2.0, self.poll_snapshot)
        self.poll_snapshot()

    def poll_snapshot(self):
        try:
            mtime = self.snapshot_path.stat().st_mtime
        except FileNotFoundError:
            self.query_one(SyncStatus).data = None
            return
        # Re-render on every tick (so the sync clock advances) but only
        # reparse the file when it has actually changed.
        if mtime != self._mtime:
            self._mtime = mtime
            try:
                data = json.loads(self.snapshot_path.read_text())
            except (json.JSONDecodeError, OSError):
                return  # mid-write; the poller writes atomically, try again next tick
            self._data = data
            self.query_one(Notices).notices = data.get("notices") or []
            self.query_one(Hero).data = data
            self.query_one(Tiles).data = data
            self.query_one(Targets).data = data
            self.query_one(Alternatives).data = data
            self.query_one(Scarcity).data = data
            self.query_one(Roster).data = data
            self.query_one(BoardTable).board = data.get("board") or []
        self.query_one(SyncStatus).data = getattr(self, "_data", None)

    def _update_controls(self):
        bt = self.query_one(BoardTable)
        self.query_one("#controls", Static).update(
            f"Available players   [pos: {bt.pos_filter}]   "
            f"[hide drafted: {'on' if bt.hide_drafted else 'off'}]   "
            f"(p to cycle position, h to toggle)"
        )

    def action_cycle_filter(self):
        bt = self.query_one(BoardTable)
        i = POS_ORDER.index(bt.pos_filter)
        bt.pos_filter = POS_ORDER[(i + 1) % len(POS_ORDER)]
        self._update_controls()

    def action_toggle_hide(self):
        bt = self.query_one(BoardTable)
        bt.hide_drafted = not bt.hide_drafted
        self._update_controls()


def main():
    snapshot_path = Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_SNAPSHOT
    DraftBoardApp(snapshot_path).run()


if __name__ == "__main__":
    main()
