# Connects to an ESPN fantasy league via ffscrapr and translates its
# real scoring rules + roster settings into ffanalytics's format, so
# player projections/VOR reflect this specific league instead of
# generic defaults.

suppressMessages({
  library(ffscrapr)
  library(ffanalytics)
  library(dplyr)
})

espn_league_connect <- function(league_id, season, espn_s2, swid) {
  espn_connect(season = season, league_id = league_id, espn_s2 = espn_s2, swid = swid)
}

# Maps an ff_scoring() tibble (ESPN's flat stat_name/points table) onto
# ffanalytics::custom_scoring() arguments. Falls back silently on any
# stat_name ffanalytics has no equivalent bucket for (e.g. exotic IDP
# or return-yardage bonuses), since those don't move offensive rankings.
translate_espn_scoring <- function(scoring_tbl) {
  off <- scoring_tbl %>%
    filter(pos %in% c("QB", "RB", "WR", "TE"), points != 0, !is.na(stat_name)) %>%
    distinct(stat_name, points) %>%
    { setNames(as.list(.$points), .$stat_name) }

  k <- scoring_tbl %>%
    filter(pos == "K", points != 0, !is.na(stat_name)) %>%
    distinct(stat_name, points) %>%
    { setNames(as.list(.$points), .$stat_name) }

  dst <- scoring_tbl %>%
    filter(pos == "DST", points != 0, !is.na(stat_name)) %>%
    distinct(stat_name, points) %>%
    { setNames(as.list(.$points), .$stat_name) }

  g <- function(map, name, default = 0) if (!is.null(map[[name]])) map[[name]] else default

  args <- list(
    pass_yds = g(off, "passingYards", 0.04),
    pass_tds = g(off, "passingTouchdowns", 4),
    pass_int = g(off, "passingInterceptions", -2),
    rush_yds = g(off, "rushingYards", 0.1),
    rush_tds = g(off, "rushingTouchdowns", 6),
    rec      = g(off, "receivingReceptions", 0),
    rec_yds  = g(off, "receivingYards", 0.1),
    rec_tds  = g(off, "receivingTouchdowns", 6),
    fumbles_lost = g(off, "lostFumbles", -2),
    two_pts  = g(off, "passing2PtConversions", g(off, "rushing2PtConversions", g(off, "receiving2PtConversions", 2))),
    xp       = g(k, "madeExtraPoints", 1),
    fg_0019  = g(k, "madeFieldGoalsFromUnder40", 3),
    fg_2029  = g(k, "madeFieldGoalsFromUnder40", 3),
    fg_3039  = g(k, "madeFieldGoalsFromUnder40", 3),
    fg_4049  = g(k, "madeFieldGoalsFrom40To49", 4),
    fg_50    = g(k, "madeFieldGoalsFrom50To59", g(k, "madeFieldGoalsFrom60Plus", 5)),
    fg_miss  = g(k, "missedFieldGoalsFromUnder40", 0),
    dst_fum_rec = g(dst, "defensiveFumbles", 2),
    dst_int     = g(dst, "defensiveInterceptions", 2),
    dst_safety  = g(dst, "defensiveSafeties", 2),
    dst_sacks   = g(dst, "defensiveSacks", 1),
    dst_blk     = g(dst, "defensiveBlockedKicks", 1.5),
    dst_td      = g(dst, "defensiveBlockedKickForTouchdowns",
                     g(dst, "interceptionReturnTouchdown",
                       g(dst, "fumbleReturnTouchdown", 6)))
  )

  sc <- do.call(custom_scoring, args)

  # Build the DST points-allowed bracket from ESPN's "defensive<range>PointsAllowed"
  # categories: parse the lower bound of each range as the bracket threshold.
  pa <- dst[grepl("PointsAllowed$", names(dst))]
  if (length(pa) > 0) {
    lower_bound <- function(nm) {
      nm <- sub("^defensive", "", sub("PointsAllowed$", "", nm))
      if (grepl("^\\d+Plus", nm)) return(as.numeric(sub("Plus", "", nm)))
      if (grepl("^\\d+To\\d+", nm)) return(as.numeric(sub("To.*$", "", nm)))
      as.numeric(gsub("\\D", "", nm))
    }
    thresholds <- vapply(names(pa), lower_bound, numeric(1))
    ord <- order(thresholds)
    sc$pts_bracket <- lapply(ord, function(i) list(threshold = unname(thresholds[i]), points = unname(pa[[i]])))
  } else {
    sc$pts_bracket <- scoring$pts_bracket
  }

  sc
}

# Returns the caller's roster construction: named vector of starter slot
# counts per position plus bench size, used for need-based recommendations.
espn_roster_needs <- function(conn) {
  sp <- ff_starter_positions(conn)
  setNames(sp$max, sp$pos)
}

# Checks whether the draft board's pick order is internally consistent.
#
# Everything downstream - "picks away", the VONA horizon, next-pick targets -
# reads pick ownership straight off ESPN's board. Before a draft starts that
# board can hold provisional rows, so a round that breaks the pattern means
# those numbers may shift once the draft goes live. Report it rather than
# quietly planning against an order that may not hold.
pick_order_check <- function(draft_board) {
  d <- draft_board[order(draft_board$overall), ]
  rounds <- split(d$franchise_id, d$round)
  rounds <- rounds[order(as.integer(names(rounds)))]
  if (length(rounds) < 2) return(list(pattern = "unknown", detail = NULL))

  r1 <- rounds[[1]]
  shape <- vapply(rounds, function(o) {
    if (identical(o, r1)) "fwd" else if (identical(o, rev(r1))) "rev" else "other"
  }, character(1))

  scrambled <- which(shape == "other")
  if (length(scrambled) > 0) {
    return(list(pattern = "irregular", detail = sprintf(
      "Round%s %s %s neither round 1's order nor its reverse, so pick ownership may be provisional.",
      if (length(scrambled) == 1) "" else "s", paste(scrambled, collapse = ", "),
      if (length(scrambled) == 1) "matches" else "match")))
  }

  if (all(shape == "fwd")) return(list(pattern = "linear", detail = NULL))

  # A snake never runs the same order twice in a row, whichever phase it starts on.
  repeats <- which(shape[-1] == shape[-length(shape)]) + 1L
  if (length(repeats) == 0) return(list(pattern = "snake", detail = NULL))

  list(
    pattern = "irregular",
    detail = sprintf(
      "Round%s %s repeat%s the previous round's order instead of reversing; the remaining rounds do alternate. Before draft day, confirm your pick slots in ESPN - these numbers drive \"picks away\" and the next-pick targets.",
      if (length(repeats) == 1) "" else "s",
      paste(repeats, collapse = ", "),
      if (length(repeats) == 1) "s" else "")
  )
}
