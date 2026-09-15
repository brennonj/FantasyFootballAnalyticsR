# Waiver-wire add/drop recommendations.
#
# The question is never "is this free agent better than my worst matching
# player" in isolation - it's "does my roster actually start more points
# because of this move." A free agent who beats your worst bench player at
# his position doesn't help you this week unless he's ALSO good enough to
# crack your actual starting lineup - if that bench player was never going
# to play anyway, "beating" him doesn't put a single extra point on your
# scoreboard. (Caught live, 2026-09-15: the tool recommended TE adds "over"
# AJ Barner using his raw points, without checking that Barner was already
# benched - the correct question was whether the new TE would actually start.)
#
# So this reuses the same lineup-value simulation as the trade evaluator
# (lineup_value()/optimize_starters(), from Lineup Tool/optimize_lineup.R):
# pick a likely drop candidate, then simulate swapping him for the free
# agent and see how much the roster's OPTIMAL starting lineup value actually
# moves - on both horizons that matter differently:
#
#   long_term  = season-long VOR (from the same league-scored, VOR-baselined
#                projections the draft tool uses - see espn_league.R). The
#                real cost of the transaction: a roster spot given up for
#                the rest of the season.
#   short_term = this week's projected-points (ffanalytics weekly pull).
#                Matters for an immediate need (bye week, injury fill-in)
#                the season number alone wouldn't flag - a strong ROS play
#                can still be on a bye this week, and a mediocre ROS play
#                can be a great one-week streamer.
#
# score = short_term_gain + 0.4 * long_term_gain - this week leads, season
# value adjusts. This league is head-to-head (Brennon, 2026-09-15): unlike
# the draft tool's VOR + 0.5*VONA (a rest-of-draft value question, where
# timing is genuinely secondary - see draft-tool-scoring-decisions memory),
# a waiver add in a head-to-head league can decide whether THIS week's
# matchup is won, so short-term isn't a minor adjustment here - it leads.
# Season VOR still counts (0.4x) so a real one-week-only rental doesn't
# outrank an add that helps both this week and every week after.
#
# Pure functions only - no Shiny, no network. Requires optimize_lineup.R
# (lineup_value, optimize_starters) to already be sourced.

suppressMessages(library(dplyr))

# The weakest rostered player a free agent could actually replace: among
# players eligible for at least one of the same base positions, the one with
# the lowest season-long VOR - preferring the bench. Season VOR alone isn't
# a safe way to reach into the active lineup: a player can be a fine, even
# good, START for THIS week while still projecting as the worst asset at his
# position for the rest of the season (2026-09-16: Jayden Reed, this
# league's actual started flex play that week, had the single lowest season
# VOR of any rostered WR - a hair below a benched one - and got proposed as
# the drop purely because of that razor-thin margin, even though cutting him
# meant immediately needing to replace him in the real lineup with an
# unproven waiver add). Only fall through to a starter when no bench player
# at a matching position exists at all - the same reasoning the standing
# "value leads, timing adjusts" score already applies elsewhere: touching
# the active lineup is a real cost recommend_adds()'s gain calculation
# doesn't otherwise price in, so it shouldn't be reached for on a coin-flip
# margin against an available bench cut.
worst_replaceable <- function(roster, target_eligible_pos) {
  candidates <- roster %>%
    filter(vapply(eligible_pos, function(e) any(target_eligible_pos %in% e), logical(1)))
  if (nrow(candidates) == 0) return(NULL)

  bench <- candidates %>% filter(current_slot %in% c("BE", "IR"))
  pool <- if (nrow(bench) > 0) bench else candidates
  pool %>% arrange(points_vor) %>% slice(1)
}

# free_agents / roster: player_id, player_name, pos, eligible_pos (list-col),
#   injury_status, percent_owned, percent_change, points_vor (season, VOR-
#   baselined), week_points (this week's projection)
# slots: data.frame of pos, min, max, as returned by ff_starter_positions()
# roster_size: total roster slots (starters + bench + IR) from ff_league() -
#   when the roster isn't already full (e.g. a player just moved to IR,
#   opening a real bench spot - caught live, 2026-09-16), the best move is
#   often a plain add with nobody dropped, which a drop-required search can
#   never surface. Optional (NA skips this) only because older callers/tests
#   may not have it.
recommend_adds <- function(free_agents, roster, slots, roster_size = NA_integer_, top_n = 15) {
  if (nrow(free_agents) == 0 || nrow(roster) == 0) return(tibble())

  long_before <- lineup_value(roster, slots, "points_vor")
  short_before <- lineup_value(roster, slots, "week_points")

  # Never recommend a player we have no real projection for, on EITHER
  # horizon - see has_season_projection/has_week_projection in
  # waiver_setup.R. A player real on only one horizon (e.g. an unranked
  # rookie with a week-2 number but no season projection at all) would
  # otherwise get a fabricated 0 on the other, silently misrepresenting an
  # unknown value as a known, replacement-level one.
  eligible_fas <- free_agents %>% filter(has_season_projection, has_week_projection)
  if (nrow(eligible_fas) == 0) return(tibble())

  score_after <- function(after_roster) {
    long_gain <- round(lineup_value(after_roster, slots, "points_vor") - long_before, 1)
    short_gain <- round(lineup_value(after_roster, slots, "week_points") - short_before, 1)
    list(long_gain = long_gain, short_gain = short_gain,
         score = round(short_gain + 0.4 * long_gain, 1))
  }

  fa_row <- function(fa) tibble(player_id = fa$player_id, player_name = fa$player_name,
                                pos = fa$pos, points_vor = fa$points_vor,
                                week_points = fa$week_points, eligible_pos = list(fa$eligible_pos))

  open_slots <- if (is.na(roster_size)) 0L else max(roster_size - nrow(roster), 0L)

  # A roster spot open at all (ESPN bench slots take any position) beats
  # cutting someone to make room every time - adding a player can never make
  # the optimizer's chosen lineup worse, while removing one can only ever
  # help or be neutral for HIM at best. So when a slot is open, skip the
  # drop-required search entirely rather than compute numbers a real open
  # slot would always match or beat.
  if (open_slots > 0) {
    out <- eligible_fas %>%
      rowwise() %>%
      mutate(
        gains = list(score_after(bind_rows(roster, fa_row(pick(everything()))))),
        drop_player = NA_character_,
        drop_pos = NA_character_,
        long_term_gain = gains$long_gain,
        short_term_gain = gains$short_gain,
        score = gains$score
      ) %>%
      ungroup() %>%
      select(-gains) %>%
      filter(score > 0) %>%
      arrange(desc(score)) %>%
      slice_head(n = top_n)
  } else {
    candidates <- eligible_fas %>%
      rowwise() %>%
      mutate(drop = list(worst_replaceable(roster, eligible_pos))) %>%
      ungroup() %>%
      filter(!vapply(drop, is.null, logical(1)))

    if (nrow(candidates) == 0) return(tibble())

    out <- candidates %>%
      rowwise() %>%
      mutate(
        drop_player = drop$player_name,
        drop_pos = drop$pos,
        gains = list(score_after(bind_rows(
          roster %>% filter(player_id != drop$player_id), fa_row(pick(everything()))
        ))),
        long_term_gain = gains$long_gain,
        short_term_gain = gains$short_gain,
        score = gains$score
      ) %>%
      ungroup() %>%
      select(-drop, -gains) %>%
      filter(score > 0) %>%
      arrange(desc(score)) %>%
      slice_head(n = top_n)
  }

  if (nrow(out) == 0) return(out)

  out %>%
    rowwise() %>%
    mutate(why = build_waiver_reason(player_name, pos, injury_status, percent_owned,
                                     percent_change, drop_player, drop_pos,
                                     long_term_gain, short_term_gain)) %>%
    ungroup()
}

build_waiver_reason <- function(player, pos, injury_status, pct_owned, pct_change,
                                drop_player, drop_pos, long_gain, short_gain) {
  bits <- character(0)

  bits <- c(bits, sprintf("%s%.1f pts this week (starting lineup impact)", if (short_gain >= 0) "+" else "", short_gain))
  bits <- c(bits, if (is.na(drop_player)) {
    sprintf("+%.0f season VOR · fills your open roster spot, no drop needed", long_gain)
  } else {
    sprintf("+%.0f season VOR · drop %s", long_gain, drop_player)
  })
  if (!is.na(injury_status) && injury_status != "ACTIVE") {
    bits <- c(bits, injury_status)
  }
  if (!is.na(pct_owned)) {
    trend <- if (!is.na(pct_change) && pct_change > 0.02) ", rising" else ""
    bits <- c(bits, sprintf("%.0f%% owned%s", pct_owned, trend))
  }

  paste(bits, collapse = " · ")
}
