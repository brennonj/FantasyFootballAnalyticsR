# Weekly Lineup Optimizer

Same league/scoring setup as the draft tool - see `DRAFT_DAY.md` for league
details. This tool answers one question each week: **is your current ESPN
lineup actually your best one, given this week's projections?**

## Run it

```bash
cd ~/Developer/FantasyFootball

# 1. Pull this week's projections (run Tue/Wed, after early-week injury
#    designations land - the app loads this once at startup and won't
#    re-check it while running)
Rscript "R Scripts/Projections/ffanalytics/pull_week_projections.R"

# 2a. Web app
./start-lineup-optimizer.sh          # http://127.0.0.1:3839

# 2b. ...or the SSH-friendly terminal version
./lineup-optimizer-tui.sh
```

`pull_week_projections.R` with no argument pulls ESPN's own current
scoring period automatically; pass a week number to pull a specific week
instead (e.g. for planning a bye week ahead).

## Reading it

- **Recommended swaps** - only shows slots where the optimal lineup differs
  from what ESPN currently has set. An empty list means your lineup is
  already optimal for this week's numbers.
- **Check before kickoff** - anyone in the *optimal* lineup flagged
  Questionable/Doubtful/Out/IR, or projected exactly 0 with no injury
  designation (almost always a bye week). The tool doesn't auto-bench these
  players - a Questionable tag is often still a starter - it just surfaces
  them so you can make the final call with real news, since projections are
  only as fresh as the last pull.
- **Gain** - total projected points if you make every recommended swap. A
  small gain (1-2 pts) usually isn't worth chasing over a real risk (e.g.
  benching a proven floor for a boom/bust flex play); the swap list shows you
  the trade, not just the verdict.

## Where it's blind

- **Flex/roster math only** - it optimizes who starts, not who to add or
  drop. That's the waiver-wire tool.
- **No matchup or weather adjustment** - it trusts the aggregated projection
  as-is, the same way the draft tool does.
- **Projections go stale between pulls.** If injury news breaks after you
  last ran the pull script, the tool won't know until you run it again.
