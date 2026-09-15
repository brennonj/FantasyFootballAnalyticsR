# Pure waiver-wire state, shared between the Shiny web app (waiver_app.R)
# and the SSH/TUI snapshot poller (waiver_snapshot.R). Mirrors the shape of
# Draft Tool/draft_state.R and Lineup Tool/lineup_state.R.
#
# Requires optimize_lineup.R (lineup_value, optimize_starters) and
# waiver_analyze.R (recommend_adds) to already be sourced.

suppressMessages(library(dplyr))

# max_roster_size: total roster slots from ff_league() (starters + bench +
# IR combined) - distinct from this function's own `roster_count` (how many
# players are actually rostered right now). recommend_adds() needs the gap
# between them to know whether an open spot lets it skip straight to "add,
# no drop needed."
compute_waiver_board <- function(my_roster, free_agents, slots, max_roster_size = NA_integer_, top_n = 15) {
  recs <- recommend_adds(free_agents, my_roster, slots, roster_size = max_roster_size, top_n = top_n)
  list(
    recommendations = recs,
    roster_count = nrow(my_roster),
    open_slots = if (is.na(max_roster_size)) NA_integer_ else max(max_roster_size - nrow(my_roster), 0L),
    pool_size = nrow(free_agents)
  )
}
