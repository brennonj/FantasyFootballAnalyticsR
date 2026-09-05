# Pure trade-tool state, shared between the Shiny web app (trade_app.R) and
# the SSH/TUI snapshot poller (trade_snapshot.R). Mirrors the shape of
# Lineup Tool/lineup_state.R and Waiver Tool/waiver_state.R.
#
# Requires trade_analyze.R (evaluate_trade, find_trade_recommendations) and
# espn_trade_data.R (trade_teams/trade_gives/trade_receives) to already be
# sourced.

suppressMessages(library(dplyr))

# Every pending trade that involves my franchise, evaluated on both sides -
# a verdict Brennon can act on before it expires or gets accepted out from
# under him.
compute_pending_evaluations <- function(pending_trades, my_franchise_id, all_rosters, slots, franchises) {
  if (nrow(pending_trades) == 0) return(tibble())

  team_name <- function(fid) {
    n <- franchises$franchise_name[franchises$franchise_id == fid]
    if (length(n) == 0) paste0("Team ", fid) else n
  }

  rows <- lapply(seq_len(nrow(pending_trades)), function(i) {
    t <- pending_trades[i, ]
    items <- t$items[[1]]
    teams <- trade_teams(items)
    if (!(my_franchise_id %in% teams)) return(NULL)

    other_id <- setdiff(teams, my_franchise_id)[1]
    my_gives <- trade_gives(items, my_franchise_id)
    my_receives <- trade_receives(items, my_franchise_id)
    if (length(my_gives) == 0 && length(my_receives) == 0) return(NULL)

    their_roster <- all_rosters %>% filter(franchise_id == other_id)
    my_roster <- all_rosters %>% filter(franchise_id == my_franchise_id)
    ev <- evaluate_trade(my_roster, their_roster, my_gives, my_receives, slots)

    tibble(
      transaction_id = t$transaction_id,
      proposed_date = t$proposed_date,
      opponent = team_name(other_id),
      give_players = paste(my_roster$player_name[match(my_gives, my_roster$player_id)], collapse = ", "),
      receive_players = paste(their_roster$player_name[match(my_receives, their_roster$player_id)], collapse = ", "),
      my_long_gain = ev$my_long_gain, my_short_gain = ev$my_short_gain,
      their_long_gain = ev$their_long_gain, my_score = ev$my_score,
      verdict = if (ev$my_score > 1) "ACCEPT" else if (ev$my_score < -1) "DECLINE" else "MARGINAL"
    )
  })

  bind_rows(rows)
}

# 1-for-1 trades worth proposing, across every other franchise, with names
# attached for display.
compute_trade_recommendations <- function(my_roster, other_rosters, slots, franchises, top_n = 10) {
  recs <- find_trade_recommendations(my_roster, other_rosters, slots, top_n = top_n)
  if (nrow(recs) == 0) return(recs)
  recs %>%
    left_join(franchises %>% select(opponent_id = franchise_id, opponent = franchise_name),
              by = "opponent_id")
}
