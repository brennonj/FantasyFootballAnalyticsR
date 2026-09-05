# Waiver-wire add/drop recommendations.
#
# The question is never "is this free agent good" in isolation - it's
# "is this free agent better than the worst player I'd actually have to cut
# for him," on both horizons that matter differently:
#
#   long_term  = season-long VOR gap (from the same league-scored, VOR-baselined
#                projections the draft tool uses - see espn_league.R). This is
#                the real cost of the transaction: a roster spot given up for
#                the rest of the season.
#   short_term = this week's projected-points gap (ffanalytics weekly pull).
#                Matters for an immediate need (bye week, injury fill-in) that
#                the season number alone wouldn't flag - a strong ROS play can
#                still be on a bye this week, and a mediocre ROS play can be a
#                great one-week streamer.
#
# score = long_term_gain + 0.5 * short_term_gain - long-term leads, this
# week's number adjusts. Same "value leads, timing adjusts" shape as the
# draft tool's VOR + 0.5*VONA (see draft-tool-scoring-decisions memory) for
# the same reason: a one-week gap is real but shouldn't outweigh a
# full-season value gap the way a naive sum would let it.
#
# Pure functions only - no Shiny, no network.

suppressMessages(library(dplyr))

# The weakest rostered player a free agent could actually replace: among
# players eligible for at least one of the same base positions, the one with
# the lowest season-long VOR. That's who a manager would really cut - not
# the best player at the position, and not restricted to bench-only, since a
# free agent can also be a real upgrade over a struggling starter.
worst_replaceable <- function(roster, eligible_pos) {
  candidates <- roster %>%
    filter(vapply(eligible_pos_list, function(e) any(eligible_pos %in% e), logical(1)))
  if (nrow(candidates) == 0) return(NULL)
  candidates %>% arrange(points_vor) %>% slice(1)
}

# free_agents / roster: player_id, player_name, pos, eligible_pos (list-col),
#   injury_status, percent_owned, percent_change, points_vor (season, VOR-
#   baselined), week_points (this week's projection)
recommend_adds <- function(free_agents, roster, top_n = 15) {
  if (nrow(free_agents) == 0 || nrow(roster) == 0) return(tibble())

  roster <- roster %>% rename(eligible_pos_list = eligible_pos)

  out <- free_agents %>%
    rowwise() %>%
    mutate(drop = list(worst_replaceable(roster, eligible_pos))) %>%
    ungroup() %>%
    filter(!vapply(drop, is.null, logical(1))) %>%
    rowwise() %>%
    mutate(
      drop_player = drop$player_name,
      drop_pos = drop$pos,
      drop_vor = drop$points_vor,
      drop_week_points = drop$week_points,
      long_term_gain = round(points_vor - drop_vor, 1),
      short_term_gain = round(week_points - drop_week_points, 1),
      score = round(long_term_gain + 0.5 * short_term_gain, 1)
    ) %>%
    ungroup() %>%
    select(-drop) %>%
    filter(score > 0) %>%
    arrange(desc(score)) %>%
    slice_head(n = top_n) %>%
    rowwise() %>%
    mutate(why = build_waiver_reason(player_name, pos, injury_status, percent_owned,
                                     percent_change, drop_player, drop_pos,
                                     long_term_gain, short_term_gain)) %>%
    ungroup()

  out
}

build_waiver_reason <- function(player, pos, injury_status, pct_owned, pct_change,
                                drop_player, drop_pos, long_gain, short_gain) {
  bits <- character(0)

  bits <- c(bits, sprintf("+%.0f season VOR over %s", long_gain, drop_player))
  if (abs(short_gain) >= 1) {
    bits <- c(bits, sprintf("%s%.1f pts this week", if (short_gain > 0) "+" else "", short_gain))
  }
  if (!is.na(injury_status) && injury_status != "ACTIVE") {
    bits <- c(bits, injury_status)
  }
  if (!is.na(pct_owned)) {
    trend <- if (!is.na(pct_change) && pct_change > 0.02) ", rising" else ""
    bits <- c(bits, sprintf("%.0f%% owned%s", pct_owned, trend))
  }

  paste(bits, collapse = " · ")
}
