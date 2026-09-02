# Draft pick recommendation engine.
#
# The objective is not "who is the best player left" (raw VOR) but "who will I
# lose if I don't take them now" - the opportunity cost between this pick and
# the team's next one. That is VONA: Value Over Next Available.
#
# score = VONA x roster-need multiplier, where
#   VONA(player) = player VOR - E[best VOR still available at that position
#                                when this team picks again]
#
# Pure functions only - no Shiny, no network - so the logic can be tested
# against a simulated draft state.

suppressMessages(library(dplyr))

# Where each player on the board is actually expected to go.
#
# Raw ADP is a redraft-market prior over a FULL pool, and it goes stale the
# moment this draft diverges from that pool. Keepers are the worst case: they
# remove players without consuming a pick, so everyone behind them lasts longer
# than ADP claims. A player still sitting on the board at pick 18 with an ADP of
# 9 is evidence that this room is passing on him - not proof he is already gone,
# which is what a static prior would insist.
#
# Ranking only the players who are ACTUALLY available and laying them out from
# the current pick is self-correcting: keepers, reaches and runs all show up as
# changes in who remains, with no special handling for any of them.
add_implied_slot <- function(board, current_pick) {
  board$implied_slot <- current_pick +
    rank(board$adp_avg, ties.method = "first", na.last = TRUE) - 1
  board
}

# Probability a player is still on the board when `target_pick` comes up.
#
# Models the realized slot as Normal(expected_slot, sigma). adp_sd measures how
# much the ADP *sources* disagree with each other, which badly understates real
# draft-day variance (the consensus 1.01 has adp_sd ~0.3, but he is not a 99.9%
# lock to go first), so sigma floors at both 3 picks and 14% of the slot.
survival_prob <- function(expected_slot, adp_sd, target_pick) {
  sigma <- pmax(adp_sd, 0.14 * expected_slot, 3, na.rm = TRUE)
  p <- 1 - pnorm(target_pick - 0.5, mean = expected_slot, sd = sigma)
  pmin(pmax(p, 0), 1)
}

# Expected best value still available at a position at a future pick.
#
# P(player i is the best one left) = P(i survives) x P(everyone better is gone),
# treating players' draft outcomes as independent. Any residual probability
# that the whole list is gone falls back to replacement level.
#
# Only the top `depth` players at the position are considered: the tail of a
# 592-player board is hundreds of players nobody would ever start, and letting
# them serve as the replacement floor makes every pick look falsely urgent.
expected_best_available <- function(values, surv, depth = 24) {
  if (length(values) == 0) return(0)
  ord <- order(values, decreasing = TRUE)
  keep <- head(ord, depth)
  v <- values[keep]
  s <- surv[keep]
  better_all_gone <- cumprod(c(1, 1 - s[-length(s)]))
  p_is_best <- s * better_all_gone
  sum(v * p_is_best) + (1 - sum(p_is_best)) * min(v)
}

# The flex is ONE slot shared by RB/WR/TE, but ESPN reports each of those
# positions' max as its dedicated slots plus the flex - so the maxes sum to more
# lineup spots than exist (RB3 + WR3 + TE2 = 8 for six real slots). Deriving the
# count keeps every position from believing it owns the flex outright.
derive_flex_slots <- function(slots) {
  fe <- slots[slots$pos %in% c("RB", "WR", "TE"), ]
  if (nrow(fe) == 0) return(0L)
  as.integer(max(fe$max - fe$min, na.rm = TRUE))
}

# How much each position is worth to THIS roster right now.
#
# Computed across the whole roster rather than per position, because whether a
# player is a starter depends on what else is already rostered: the second tight
# end is only startable if nothing has claimed the flex yet. Kickers and
# defenses stay suppressed until the last two rounds, since taking one early
# forfeits a real starter.
roster_multipliers <- function(filled, slots, rounds_left,
                               flex_slots = derive_flex_slots(slots)) {
  pos <- slots$pos
  mins <- setNames(slots$min, pos)
  flex_pos <- intersect(pos, c("RB", "WR", "TE"))

  dedicated_left <- setNames(pmax(mins[pos] - filled[pos], 0), pos)
  claimed_flex <- sum(pmax(filled[flex_pos] - mins[flex_pos], 0))
  flex_open <- max(flex_slots - claimed_flex, 0)

  starters_left <- sum(dedicated_left) + flex_open
  urgent <- starters_left >= rounds_left

  setNames(vapply(pos, function(p) {
    m <- if (dedicated_left[[p]] > 0) {
      1                                            # fills a dedicated slot
    } else if (p %in% flex_pos && flex_open > 0) {
      0.55                                         # only the flex left, and RB/WR/TE all compete for it
    } else if (p %in% flex_pos) {
      0.3                                          # bench depth
    } else if (p == "QB") {
      0.15
    } else {
      0.05
    }

    if (p %in% c("K", "DST")) {
      if (rounds_left > 2) m <- m * 0.12
      if (filled[[p]] >= 1) m <- 0.05
    }

    # Running out of picks to fill mandatory slots makes them urgent.
    if (urgent && dedicated_left[[p]] > 0) m <- m * 1.4

    m
  }, numeric(1)), pos)
}

# Tier state for a position: how many players are left in the top remaining
# tier, and how far the value falls once that tier is gone.
tier_state <- function(pos_board) {
  if (nrow(pos_board) == 0) return(list(n_in_tier = 0, drop = 0, tier = NA))
  top_tier <- pos_board$tier[which.max(pos_board$points_vor)]
  in_tier <- pos_board[pos_board$tier %in% top_tier, ]
  below <- pos_board[!(pos_board$tier %in% top_tier), ]
  drop <- if (nrow(below) == 0) 0 else max(in_tier$points_vor) - max(below$points_vor)
  list(n_in_tier = nrow(in_tier), drop = drop, tier = top_tier)
}

# Roster slot counts for a franchise, given the picks made so far.
roster_filled <- function(picks_so_far, franchise_id, positions) {
  positions <- unname(as.character(positions))
  mine <- picks_so_far[picks_so_far$franchise_id == franchise_id, ]
  setNames(
    vapply(positions, function(p) sum(mine$pos == p, na.rm = TRUE), integer(1)),
    positions
  )
}

# Main entry point.
#
#   board          available players: id, player, pos, team, points, points_vor,
#                  tier, adp_avg, adp_sd
#   picks_so_far   completed picks: franchise_id, pos
#   franchise_id   the team on the clock
#   current_pick   this team's current overall pick number
#   next_pick      that team's next overall pick (NA if none left)
#   slots          data.frame of pos, min, max starter slots
#   rounds_left    rounds remaining for this team, including the current one
recommend_picks <- function(board, picks_so_far, franchise_id, current_pick,
                            next_pick, slots, rounds_left, top_n = 6) {
  if (nrow(board) == 0) return(tibble())

  # ff_starter_positions() returns pos as a vector named by ESPN slot ids;
  # strip that so positions index by name ("QB") rather than slot id ("0").
  slots <- slots %>%
    mutate(pos = unname(as.character(pos)),
           min = as.integer(min),
           max = as.integer(max))

  positions <- slots$pos
  filled <- roster_filled(picks_so_far, franchise_id, positions)
  pos_mult <- roster_multipliers(filled, slots, rounds_left)

  # With no future pick to wait for, opportunity cost is just the player's value.
  horizon <- if (is.na(next_pick)) current_pick + 1 else next_pick

  board <- add_implied_slot(board, current_pick) %>%
    mutate(surv_next = survival_prob(implied_slot, adp_sd, horizon))

  pos_expectations <- lapply(positions, function(p) {
    pb <- board[board$pos == p, ]
    list(
      pos = p,
      e_best = if (nrow(pb) == 0) 0 else expected_best_available(pb$points_vor, pb$surv_next),
      tier = tier_state(pb)
    )
  })
  names(pos_expectations) <- positions

  out <- board %>%
    rowwise() %>%
    mutate(
      e_best_later = pos_expectations[[pos]]$e_best,
      vona = points_vor - e_best_later,
      need_mult = pos_mult[[pos]],
      # Value leads; timing adjusts. VONA measures only what is lost between this
      # pick and the next one, which badly overstates positions with a steep top
      # and a shallow tail: elite QB looks urgent because QB2 is far below QB1,
      # even though a 1-QB league needs exactly one and can wait rounds for him.
      # Letting VONA dominate put a QB ahead of a running back with a 50-point
      # larger VOR edge. Half weight keeps scarcity influential - it still lifts
      # a thin-position starter over a marginally better pick at a deep one -
      # without letting a local timing gap outrank a large value gap.
      score = need_mult * (points_vor + 0.5 * vona)
    ) %>%
    ungroup() %>%
    arrange(desc(score))

  out %>%
    slice_head(n = top_n) %>%
    rowwise() %>%
    mutate(why = build_reason(pos, surv_next, vona, need_mult,
                              pos_expectations[[pos]]$tier,
                              filled[[pos]],
                              slots$min[slots$pos == pos],
                              horizon, is.na(next_pick))) %>%
    ungroup()
}

build_reason <- function(pos, surv, vona, need_mult, tier, n_filled, slot_min,
                         horizon, last_pick) {
  bits <- character(0)

  gone_pct <- round((1 - surv) * 100)
  if (!last_pick) {
    bits <- c(bits, paste0(gone_pct, "% gone by pick ", horizon))
  }

  if (tier$n_in_tier > 0 && tier$drop > 3) {
    bits <- c(bits, paste0(tier$n_in_tier, " left in ", pos, " tier ", tier$tier,
                           ", then -", round(tier$drop), " pts"))
  }

  if (n_filled < slot_min) {
    bits <- c(bits, paste0("fills ", pos, " starter (", n_filled, "/", slot_min, ")"))
  } else if (need_mult < 0.5) {
    bits <- c(bits, paste0(pos, " starters already set"))
  }

  paste(bits, collapse = " · ")
}
