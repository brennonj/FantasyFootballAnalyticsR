# Waiver Wire

Same league/scoring setup as the draft tool - see `DRAFT_DAY.md`. This tool
answers: **is any unrostered player worth a roster spot on my team right
now, and who would I actually have to cut for him?**

## Run it

```bash
cd ~/Developer/FantasyFootball

# 1. Both projection pulls need to be current:
Rscript "R Scripts/Projections/ffanalytics/pull_season_projections.R"   # rest-of-season value
Rscript "R Scripts/Projections/ffanalytics/pull_week_projections.R"     # this week's value

# 2a. Web app
./start-waiver-wire.sh          # http://127.0.0.1:3840

# 2b. ...or the SSH-friendly terminal version
./waiver-wire-tui.sh
```

Re-run the season pull periodically through the year, not just before the
draft - most sources keep updating their rest-of-season numbers as roles and
depth charts change, so a stale preseason pull understates a player whose
opportunity has grown.

## How it decides

Every free agent is compared against **the weakest player on your roster
he could actually replace** - not your best player at the position, and not
bench-only (a free agent that clears your worst starter is a real upgrade,
not just bench depth). Two horizons feed the recommendation:

- **Long-term** - the season-long VOR gap, using the same league-scored,
  VOR-baselined projections as the draft tool. This is the real cost of the
  move: a roster spot given up for the rest of the season.
- **Short-term** - this week's projected-points gap. Catches a need the
  season number alone would miss (bye week, injury fill-in) and rewards a
  free agent who's a great one-week streamer even if he isn't a long-term hold.

`score = long_term_gain + 0.5 * short_term_gain` - long-term leads, this
week adjusts. Same "value leads, timing adjusts" shape as the draft tool's
picks, for the same reason: a one-week gap is real but shouldn't outrank a
full-season value gap the way a naive sum would let it.

Ownership % and its trend are shown as context (a rising add rate is often
early signal of a role change other managers have already noticed) but
don't drive the score - they're not filtered through this league's scoring
or your roster's actual needs the way VOR is.

## Where it's blind

- **Doesn't know waiver priority or FAAB budget.** A recommended add may
  cost more than it's worth to actually win the claim - that judgment is
  yours.
- **No lineup awareness.** A recommended drop might currently be your
  starter; check the lineup optimizer before cutting someone mid-week.
- **Rest-of-season projections are the last pull, not truly ROS-adjusted**
  for games already played - see the note above about re-running it.
