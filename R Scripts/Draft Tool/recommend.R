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

# Probability a player is still on the board when `target_pick` comes up.
#
# Models the realized draft slot as Normal(adp, sigma). adp_sd measures how
# much the ADP *sources* disagree with each other, which badly understates
# real draft-day variance at the top of the board (the consensus 1.01 has
# adp_sd ~0.3, but he is not a 99.9% lock to go first). So sigma floors at
# both an absolute 3 picks and 14% of ADP.
survival_prob <- function(adp, adp_sd, target_pick) {
  sigma <- pmax(adp_sd, 0.14 * adp, 3, na.rm = TRUE)
  p <- 1 - pnorm(target_pick - 0.5, mean = adp, sd = sigma)
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

# How much a position is worth to THIS roster right now.
#
# A 4th RB when the starting slots are full is bench depth, not a starter
# upgrade, so it gets discounted. Kickers and defenses are suppressed until
# the last two rounds because taking one early forfeits a real starter.
need_multiplier <- function(pos, n_filled, slot_min, slot_max, rounds_left) {
  flex_eligible <- pos %in% c("RB", "WR", "TE")

  mult <- if (n_filled < slot_min) {
    1
  } else if (n_filled < slot_max) {
    if (flex_eligible) 0.8 else 0.4
  } else {
    if (flex_eligible) 0.5 else if (pos == "QB") 0.25 else 0.1
  }

  if (pos %in% c("K", "DST")) {
    if (rounds_left > 2) mult <- mult * 0.12
    if (n_filled >= 1) mult <- 0.05
  }

  # Running out of rounds to fill a mandatory slot makes it urgent.
  if (n_filled < slot_min && rounds_left <= slot_min - n_filled + 1) mult <- mult * 1.4

  mult
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

  # With no future pick to wait for, opportunity cost is just the player's value.
  horizon <- if (is.na(next_pick)) current_pick + 1 else next_pick

  board <- board %>%
    mutate(surv_next = survival_prob(adp_avg, adp_sd, horizon))

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
      need_mult = need_multiplier(
        pos,
        n_filled  = filled[[pos]],
        slot_min  = slots$min[slots$pos == pos],
        slot_max  = slots$max[slots$pos == pos],
        rounds_left = rounds_left
      ),
      # VONA alone collapses toward zero at the turn of a snake, where back-to-back
      # picks mean almost nothing gets sniped in between and the ordering becomes
      # noise. The raw-value term breaks those ties toward the better player
      # without displacing VONA when scarcity is genuinely in play.
      score = need_mult * (vona + 0.15 * points_vor)
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
