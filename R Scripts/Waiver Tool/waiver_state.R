# Pure waiver-wire state, shared between the Shiny web app (waiver_app.R)
# and the SSH/TUI snapshot poller (waiver_snapshot.R). Mirrors the shape of
# Draft Tool/draft_state.R and Lineup Tool/lineup_state.R.
#
# Requires waiver_analyze.R (recommend_adds) to already be sourced.

suppressMessages(library(dplyr))

compute_waiver_board <- function(my_roster, free_agents, top_n = 15) {
  recs <- recommend_adds(free_agents, my_roster, top_n = top_n)
  list(
    recommendations = recs,
    roster_size = nrow(my_roster),
    pool_size = nrow(free_agents)
  )
}
