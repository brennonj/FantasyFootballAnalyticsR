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

Then confirm, in the header:

- **Green dot + a ticking "synced" time.** Red means the feed is dead — see
  Troubleshooting.
- If the amber *keepers not assigned* banner is showing, all 10 keepers
  (including Amon-Ra) are still on the board. They drop off automatically when
  the commissioner locks them — no restart needed.

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

```
R2 (18)   TE  ←  Trey McBride
R3 (23)   RB
R4 (38)   RB
R5 (43)   WR
R6-R8     QB
...
R15 (143) K        R16 (158) DST
```

**Pick 18 — TE, Trey McBride.** The one unambiguous call. He's VOR 96 with the
next TE at 77 and a cliff to 35 after that, at the thinnest position in the
league (11 above replacement vs 23 each at RB/WR). If both he and Bowers are
gone, **don't reach for TE3** — take the best RB instead.

**Picks 23 / 38 / 43 — two RBs and a WR.** The order among them depends on what
the other nine teams kept, which is unknowable until it happens. Simulating both
extremes, the *sequence* changed but the *shape* never did: you finish round 5
with **2 RB, 2 WR (Amon-Ra plus one), 1 TE**. Let the board pick the order.

**QB rounds 6–8.** Don't pay early. QB collapses to near-zero VOR right after
QB1 — the gap between the QB you get in round 2 and round 8 is small, and the
tool suppresses QB accordingly once one is rostered.

**K and DST at 143 and 158, never sooner.** The tool actively suppresses them
until the final two rounds. Taking one early forfeits a real starter.

**Your keeper is doing work here.** Amon-Ra covers WR1, which is exactly why you
can afford TE-then-RB and let WR wait.

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
