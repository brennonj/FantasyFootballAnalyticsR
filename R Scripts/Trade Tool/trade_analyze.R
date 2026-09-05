# Trade evaluation and recommendation.
#
# The question for any trade - proposed to you, or one you might propose -
# isn't "who gave up more value," it's "does each side's roster actually
# start more points because of this." A 3rd-string RB's full VOR doesn't
# help a team that already has two better ones and no flex room for a
# third; the same player traded to a team starting a replacement-level RB2
# is worth his whole VOR to them. That's a lineup-assignment question, not a
# raw-value one - so this reuses the weekly lineup optimizer's ILP
# (optimize_starters(), from Lineup Tool/optimize_lineup.R) rather than
# comparing player values directly: it simulates each roster's *optimal
# starting lineup value* before and after the trade, on both horizons the
# waiver tool already uses (season VOR for long-term, this week's points for
# short-term - see waiver_analyze.R for why both matter).
#
# Pure functions only - no Shiny, no network. Requires optimize_lineup.R
# (optimize_starters) to already be sourced.

suppressMessages(library(dplyr))

# A roster's optimal starting lineup value under a given value column
# ("points_vor" for season-long, "week_points" for this week) - literally
# the weekly optimizer's objective, repointed at a different number.
lineup_value <- function(roster, slots, value_col) {
  if (nrow(roster) == 0) return(0)
  scored <- roster %>% mutate(points = .data[[value_col]])
  optimized <- optimize_starters(scored, slots)
  sum(optimized$points[optimized$assigned_slot != "BE"], na.rm = TRUE)
}

# Evaluates a hypothetical (or real, proposed) trade for both sides: swap
# `receives` into `roster` in place of `gives_ids`, and see how each side's
# optimal lineup value moves on both horizons.
evaluate_side <- function(roster, gives_ids, receives, slots) {
  after <- roster %>% filter(!(player_id %in% gives_ids)) %>% bind_rows(receives)
  list(
    long_before = lineup_value(roster, slots, "points_vor"),
    long_after = lineup_value(after, slots, "points_vor"),
    short_before = lineup_value(roster, slots, "week_points"),
    short_after = lineup_value(after, slots, "week_points")
  )
}

# my_gives/my_receives: player_id vectors. their_roster only needs to
# contain the players in my_receives (evaluate_trade doesn't need their full
# bench) unless the caller also wants their side's numbers, in which case
# pass their full roster.
evaluate_trade <- function(my_roster, their_roster, my_gives_ids, my_receives_ids, slots) {
  my_receives <- their_roster %>% filter(player_id %in% my_receives_ids)
  their_receives <- my_roster %>% filter(player_id %in% my_gives_ids)

  mine <- evaluate_side(my_roster, my_gives_ids, my_receives, slots)
  theirs <- evaluate_side(their_roster, my_receives_ids, their_receives, slots)

  my_long_gain <- round(mine$long_after - mine$long_before, 1)
  my_short_gain <- round(mine$short_after - mine$short_before, 1)
  their_long_gain <- round(theirs$long_after - theirs$long_before, 1)
  their_short_gain <- round(theirs$short_after - theirs$short_before, 1)

  list(
    my_long_gain = my_long_gain, my_short_gain = my_short_gain,
    their_long_gain = their_long_gain, their_short_gain = their_short_gain,
    my_score = round(my_long_gain + 0.5 * my_short_gain, 1)
  )
}

# 1-for-1 trade candidates across every other roster in the league, kept to
# ones that raise BOTH sides' optimal lineup value - a true win-win from
# positional fit (my surplus fills their need and vice versa), not just a
# lopsided ask. Restricted to players with positive season VOR on both ends:
# shopping roster filler for other roster filler never changes either
# lineup's optimal value, and would otherwise multiply the search space for
# zero informational gain.
find_trade_recommendations <- function(my_roster, other_rosters, slots, top_n = 10, min_gain = 1) {
  my_candidates <- my_roster %>% filter(points_vor > 0)
  if (nrow(my_candidates) == 0) return(tibble())

  my_long_before <- lineup_value(my_roster, slots, "points_vor")
  my_short_before <- lineup_value(my_roster, slots, "week_points")

  results <- vector("list", 0)
  for (fid in unique(other_rosters$franchise_id)) {
    their_roster <- other_rosters %>% filter(franchise_id == fid)
    their_candidates <- their_roster %>% filter(points_vor > 0)
    if (nrow(their_candidates) == 0) next

    their_long_before <- lineup_value(their_roster, slots, "points_vor")
    their_short_before <- lineup_value(their_roster, slots, "week_points")

    for (i in seq_len(nrow(my_candidates))) {
      mine <- my_candidates[i, ]
      for (j in seq_len(nrow(their_candidates))) {
        theirs <- their_candidates[j, ]

        my_after_roster <- my_roster %>% filter(player_id != mine$player_id) %>% bind_rows(theirs)
        their_after_roster <- their_roster %>% filter(player_id != theirs$player_id) %>% bind_rows(mine)

        my_long_gain <- round(lineup_value(my_after_roster, slots, "points_vor") - my_long_before, 1)
        if (my_long_gain < min_gain) next
        their_long_gain <- round(lineup_value(their_after_roster, slots, "points_vor") - their_long_before, 1)
        if (their_long_gain < min_gain) next

        my_short_gain <- round(lineup_value(my_after_roster, slots, "week_points") - my_short_before, 1)
        their_short_gain <- round(lineup_value(their_after_roster, slots, "week_points") - their_short_before, 1)

        results[[length(results) + 1]] <- tibble(
          opponent_id = fid,
          give_player_id = mine$player_id, give_player = mine$player_name, give_pos = mine$pos,
          receive_player_id = theirs$player_id, receive_player = theirs$player_name, receive_pos = theirs$pos,
          my_gain = my_long_gain, their_gain = their_long_gain,
          my_gain_week = my_short_gain, their_gain_week = their_short_gain
        )
      }
    }
  }

  out <- bind_rows(results)
  if (nrow(out) == 0) return(out)
  out %>%
    arrange(desc(my_gain + their_gain)) %>%
    slice_head(n = top_n) %>%
    rowwise() %>%
    mutate(why = sprintf("you +%.1f season VOR, them +%.1f - this week: you %s%.1f, them %s%.1f",
                         my_gain, their_gain,
                         if (my_gain_week >= 0) "+" else "", my_gain_week,
                         if (their_gain_week >= 0) "+" else "", their_gain_week)) %>%
    ungroup()
}
