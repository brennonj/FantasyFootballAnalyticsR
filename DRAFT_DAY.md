# Draft Day

**League:** 10 teams · full PPR · 16 rounds · round 1 is the keeper round
**Team:** Big Data Analytics (franchise 9) · **Keeper:** Amon-Ra St. Brown (WR)
**Board:** http://127.0.0.1:3838

---

## 1. Run this 30–60 minutes before

Order matters. The app loads projections **once at startup** and never re-reads
them, so pulling after launching means drafting off stale numbers all night.

```bash
cd ~/Developer/FantasyFootball

# 1. Refresh projections  (~3-5 min; scrapes 8 sources)
Rscript "R Scripts/Projections/ffanalytics/pull_season_projections.R"

# 2. Launch the board  (~30-40s to first paint, opens your browser)
./start-draft-board.sh
```

**Off your home network?** Don't port-forward the web board to the internet -
it has no login, and a bare HTTP connection to a residential IP routinely
trips ISP/router "Advanced Security" filters anyway (Safari shows this as a
block page you can't get past). Instead, SSH in and run the terminal version,
which needs no port forwarding or browser:

```bash
ssh you@this-mac "cd ~/Developer/FantasyFootball && ./draft-board-tui.sh"
```

Same recommendations, same 15s ESPN polling, computed by the same R code as
the web board - just rendered as a terminal UI instead of HTML. `p` cycles
the position filter, `h` toggles hide-drafted, `q` quits (and stops the
poller with it).

Then confirm, in the header:

- **Green dot + a ticking "synced" time.** Red means the feed is dead — see
  Troubleshooting.
- If the amber *keepers not assigned* banner is showing, all 10 keepers
  (including Amon-Ra) are still on the board. That's driven by ESPN's own
  `drafted` flag on the league, not by whether keepers are designated or
  locked in league settings — owners can have their keepers picked and the
  commissioner can have them locked, and the board will still show this
  banner (confirmed live via ESPN's API on 2026-09-06) until the draft room
  itself actually opens. It clears automatically the moment ESPN flips that
  flag — no restart needed — but not a moment before, so don't read a
  still-showing banner as a sign something needs fixing or re-locking.

---

## 2. Your picks

You draft **8th**. The snake flips you to 3rd in reversed rounds, so you pick in
tight pairs and then go dark:

| | | | | | | |
|---|---|---|---|---|---|---|
| **18** | **23** | 38 | 43 | 58 | 63 | 78 |
| 83 | 98 | 103 | 118 | 123 | 138 | **143 · 158** |

Gaps alternate **5, 15, 5, 15…** That single fact should drive every decision:

- **First pick of a pair** (18, 38, 58…) — only 5 picks until you're back. Very
  little you want disappears. **Take the best player.**
- **Second pick of a pair** (23, 43, 63…) — 15 picks of darkness ahead, roughly a
  full round and a half. **Take the position about to be strip-mined.**

---

## 3. Recommended order

**Superseded by the actual 2026 keepers.** Confirmed against the real
projections board (2026-09-06): besides Amon-Ra, nine other keepers are
locked in league-wide, and they gut exactly the plan this section used to
recommend — both McBride and Bowers (your TE1/TE2 target), three of the top
four RBs (Jahmyr Gibbs, Bijan Robinson, Christian McCaffrey), and three more
top-tier WRs (Puka Nacua, Ja'Marr Chase, Justin Jefferson). None of those ten
players will ever hit the board. ESPN's live feed won't show it until the
draft room actually opens (see Troubleshooting), so ignore any hero/alternative
recommendation that names one of them once the draft starts — the tool will
correct itself the moment ESPN's `drafted` flag flips, but not before.

```
R2 (18)   RB/WR  ←  best player available, TE no longer the lock
R3 (23)   RB/WR  ←  whichever side got strip-mined in the dark stretch
R4 (38)   RB
R5 (43)   WR
R6-R8     QB
R9-R11ish TE      ←  once VOR is competitive with the rest of the board
...
R15 (143) K        R16 (158) DST
```

**TE is no longer the round-2 lock.** With both McBride (VOR 90) and Bowers
(VOR 76) kept elsewhere, the position's cliff moved down a full tier: the
next TE is Colston Loveland at VOR 35 — exactly the "cliff to 35" this doc
already flagged as the fallback scenario, except now it's the actual board,
not a hedge. A VOR-35 TE1 isn't worth reaching for at 18. **Treat TE like
K/DST** — draft it once its VOR stops being a clear downgrade from the best
RB/WR left, not on a fixed round.

**Picks 18 and 23 — best RB/WR available.** Removing Gibbs/Robinson/McCaffrey
drops the RB ceiling to Jonathan Taylor (VOR 106) — a real tier below the
three that just disappeared. Removing Nacua/Chase/Jefferson does the same to
WR, except Jaxon Smith-Njigba (VOR 103) is a genuinely strong replacement,
nearly as valuable as the departed WR1s. Scarcity dropped too (20 RB / 19 WR
/ **9 TE** above replacement, down from 23 / 23 / 11) but the *shape* of the
old advice still holds — let the board and availability % pick the order
between 18 and 23, don't force a position.

**Revised target shape by round 5:** with elite TE off the table, aim for
something closer to **3 RB, 2 WR (Amon-Ra plus one)** rather than the old 2
RB / 2 WR / 1 TE, and pick up a TE opportunistically whenever one's VOR
stops being a clear downgrade from the RB/WR you'd otherwise take.

**QB rounds 6–8 — unchanged.** Josh Allen (VOR 59) wasn't touched by any of
the ten keepers and is still the clear QB1; the position still collapses to
near-zero VOR right after QB1 goes, so don't pay early.

**K and DST at 143 and 158, never sooner.** The tool actively suppresses them
until the final two rounds. Taking one early forfeits a real starter.

**Your keeper is doing work here.** Amon-Ra covers WR1, which is exactly why
you can spend 18 and 23 on best-player-available RB/WR instead of needing to
fill WR early, and let TE sit until its value catches up.

---

## 4. Reading the board mid-draft

| Panel | Use it for |
|---|---|
| **Hero** (blue) | Recommendation for whoever is on the clock — *including opponents*, computed against their roster. Three teams ahead all showing RB = a run is coming. |
| **Your next pick** (green) | Your planning window while others pick. Players ≥50% likely to reach you. |
| **Positional scarcity** | How many startable players remain per position. |
| **Your roster** | Starter slots still unfilled. |

Two habits worth having:

- **Break ties with the availability %.** Want both A and B? Take the one less
  likely to survive.
- **Trust tier-cliff chips over small VOR gaps.** *"1 left in tier, then −30 pts"*
  is a real decision. A 4-point VOR edge is noise.

---

## 5. Where it's blind — overrule it here

- **Availability below ~40% is unreliable.** Validated against your real 2025
  draft: players given under a 40% chance actually survived about two-thirds of
  the time. Read low numbers as "at risk," not "gone." Above 80% is well
  calibrated (~89–95% accurate).
- **ADP is the national market, not your room.** If your league reaches for QBs
  or drafts homers, availability is optimistic in exactly the spot that stings.
- **No injury news** past the projections pull. One more reason to run it late.
- **No bye weeks, handcuffs, or stacking.** It optimizes projected points and
  starter slots, nothing else.
- **Keeper bargains aren't modeled.** It knows *who* was kept once ESPN records
  it, never whether a keeper was a steal — so it can't tell you which opponents
  are over-resourced.

---

## 6. Troubleshooting

**Red dot / "STALE — no sync for N min"** — the ESPN feed is dead, most likely
expired cookies. The board is frozen on its last good state. Refresh `espn_s2`
and `SWID` from DevTools → Application → Cookies → `fantasy.espn.com`, update
`Config/espn_credentials.R`, restart.

**"Missing Config/espn_credentials.R"** — it's git-ignored, so it doesn't survive
a clone or travel with a merge. Recreate it or copy it across.

**"Port 3838 is already in use"** — it's probably already running at
http://127.0.0.1:3838. To kill it: `kill $(lsof -t -i :3838)`

**Recommendations look wrong** — check the roster panel first. Nearly every bad
recommendation in testing traced back to the tool having the wrong idea of what
was already rostered.
