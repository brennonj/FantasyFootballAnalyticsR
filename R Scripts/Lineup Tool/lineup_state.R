# Pure lineup-state computations shared between the Shiny web app
# (lineup_app.R) and the SSH/TUI snapshot poller (lineup_snapshot.R).
#
# No Shiny dependency - takes plain data frames in, returns plain lists/data
# frames out - mirroring Draft Tool/draft_state.R.
#
# Requires optimize_lineup.R (optimize_starters, compare_lineups) to already
# be sourced.

suppressMessages(library(dplyr))

# Slot display order, for rendering starters top-to-bottom in a sensible way
# rather than whatever order the optimizer happened to emit them in.
SLOT_ORDER <- c("QB", "RB", "WR", "TE", "RB/WR/TE", "K", "DST")

# ESPN's real injury_status values (confirmed live 2026-09-15) - "IR" is the
# roster SLOT code (current_slot), not an injury_status value, which is
# "INJURY_RESERVE" instead. Using "IR" here meant an IR-designated starter
# was never flagged at all, even though his 0-point projection already
# correctly kept him out of the optimal lineup on its own.
NEEDS_ATTENTION <- c("QUESTIONABLE", "DOUBTFUL", "OUT", "INJURY_RESERVE")

# Everything the UI needs for one franchise's week: the optimal lineup, the
# swaps versus what ESPN currently has set, and anything worth flagging
# (injury designations on anyone in the optimal starting 9, or a projected
# zero that isn't explained by an injury designation - almost always a bye).
compute_lineup <- function(rosters, franchise_id, slots) {
  roster <- rosters %>% filter(franchise_id == !!franchise_id)
  if (nrow(roster) == 0) return(NULL)

  optimal <- optimize_starters(roster, slots)
  swaps <- compare_lineups(optimal)

  starters <- optimal %>%
    filter(assigned_slot != "BE") %>%
    arrange(match(assigned_slot, SLOT_ORDER))
  bench <- optimal %>%
    filter(assigned_slot == "BE") %>%
    arrange(desc(points))

  current_points <- sum(roster$points[!(roster$current_slot %in% c("BE", "IR"))], na.rm = TRUE)
  optimal_points <- sum(starters$points, na.rm = TRUE)

  # Vectorized (if_else), not rowwise()+if(): a scalar if() on a zero-row
  # rowwise group - the common case, most weeks nobody needs flagging -
  # throws "argument is of length zero" instead of just producing zero rows.
  # (Found independently in two sessions the same week - see git history.)
  flags <- starters %>%
    filter(injury_status %in% NEEDS_ATTENTION | (points == 0 & injury_status == "ACTIVE")) %>%
    mutate(note = if_else(injury_status %in% NEEDS_ATTENTION,
                          paste0(injury_status, " - verify before kickoff"),
                          "projected 0 pts - check for a bye week")) %>%
    select(player_name, pos, note)

  list(
    starters = starters,
    bench = bench,
    swaps = swaps,
    current_points = round(current_points, 1),
    optimal_points = round(optimal_points, 1),
    gain = round(optimal_points - current_points, 1),
    flags = flags
  )
}
