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
