# Trade Evaluator

Same league/scoring setup as the draft tool - see `DRAFT_DAY.md`. This tool
does two things: **grades any trade sitting in your ESPN inbox**, and
**searches the rest of the league for trades worth proposing**.

## Run it

```bash
cd ~/Developer/FantasyFootball

Rscript "R Scripts/Projections/ffanalytics/pull_season_projections.R"   # rest-of-season value
Rscript "R Scripts/Projections/ffanalytics/pull_week_projections.R"     # this week's value

./start-trade-evaluator.sh          # http://127.0.0.1:3841
# ...or:
./trade-evaluator-tui.sh
```

## How it decides

Neither question is "who gave up more value" - it's "does each team's
*optimal starting lineup* actually score more points because of this."
A 3rd-string RB's full season value doesn't help a team that already has two
better ones and no flex room for a third; the same player traded to a team
starting a replacement-level RB2 is worth his whole value to them. So every
evaluation re-runs the weekly lineup optimizer's solver on both rosters,
before and after the trade, on two horizons (same as the waiver tool):
season-long VOR (the real cost - a roster spot given up for the year) and
this week's points (catches an immediate need or awkward bye-week timing the
season number alone would miss).

- **Pending trades** - every trade in your ESPN inbox gets a verdict
  (ACCEPT / DECLINE / MARGINAL) from your side's combined score
  (`season VOR gain + 0.5 * this-week gain`), plus the raw numbers so you can
  see the reasoning, not just the verdict.
- **Trade recommendations** - a 1-for-1 search across every other roster in
  the league, kept to trades that raise **both** sides' optimal lineup value.
  That's deliberate: those are the trades an opponent would plausibly accept,
  because they're not just good for you - they move each team's roster
  surplus into a slot it can actually start. It's a real search (roughly
  roster-size × league-size pairs, each re-solving the lineup optimizer
  twice), so it's triggered on demand in the web app ("Find trade
  recommendations") rather than run on every refresh; the terminal version
  recomputes it automatically every 30 minutes instead, since it has no
  button to click.

## Where it's blind

- **Confidence note on pending trades**: this was built before any real
  trade had been proposed in the league, so the ESPN item parsing (who gives//
  receives what) is inferred from the same `fromTeamId`/`toTeamId` fields
  confirmed live for adds and drops, not verified against an actual trade
  proposal. Sanity-check the first real one against what you know it says in
  ESPN's own UI.
- **1-for-1 only.** It won't find a 2-for-1 or 3-for-2 that only works as a
  package deal.
- **No sense of what an opponent actually wants.** "Both sides' lineup value
  goes up" is a good proxy for "they'd plausibly say yes," not a guarantee -
  it doesn't know if they're rebuilding, punting the season, or simply
  overvalue a specific player.
- **Same projection-staleness caveat as the other tools** - re-run both
  pulls periodically, especially the season one as roles change.
