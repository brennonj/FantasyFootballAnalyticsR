# Pulls this-week fantasy football projections using ffanalytics and writes
# them to Data/, mirroring pull_season_projections.R but for a single week
# instead of the full season (week = 0).
#
# The lineup optimizer needs week-specific numbers - a player's rest-of-season
# total says nothing about whether he plays this Sunday - so this is a
# separate pull, run weekly (Tue/Wed, after early-week injury designations)
# rather than once before the draft.
#
# Usage:
#   Rscript "R Scripts/Projections/ffanalytics/pull_week_projections.R" [week]
# With no argument, pulls ESPN's own current scoring period (see
# espn_current_week() in R Scripts/Lineup Tool/espn_lineup_data.R).

suppressMessages({
  library(ffanalytics)
  library(dplyr)
})

repo_root <- normalizePath(getwd())
season <- 2026

args <- commandArgs(trailingOnly = TRUE)
if (length(args) >= 1) {
  week <- as.integer(args[1])
} else {
  source(file.path(repo_root, "Config", "espn_credentials.R"))
  source(file.path(repo_root, "R Scripts", "Draft Tool", "espn_league.R"))
  source(file.path(repo_root, "R Scripts", "Lineup Tool", "espn_lineup_data.R"))
  conn <- espn_league_connect(espn_league_id, espn_season, espn_s2, espn_swid)
  week <- espn_current_week(conn)
}
stopifnot(!is.na(week), week >= 1, week <= 18)

cat("Pulling week", week, season, "projections...\n")

pos <- c("QB", "RB", "WR", "TE", "K", "DST")

# ffanalytics caches each source's scrape by source name alone - no
# season/week in the key - and reuses it if scraped recently regardless of
# which season/week that scrape was actually for. Without this, running
# pull_season_projections.R (week = 0, i.e. rest-of-season numbers) shortly
# before this script silently feeds season-long CBS/FantasySharks/etc. stats
# into what's supposed to be this week's projections, wildly inflating them.
# This was independently misdiagnosed once (2026-09-15) as "CBS/FantasySharks
# don't support week-specific requests" and briefly fixed by excluding both
# sources entirely - confirmed live afterward that the real cause was this
# cache collision: with the cache cleared, both return correct single-week
# numbers (CBS: 7.0 rec/77.5 yds/games=1 for a week-2 request, not the
# 115 rec/1289 yds/games=16 season line it returned when cache-contaminated).
# Restored to the full source list below.
clear_ffanalytics_cache()

raw_scrape <- scrape_data(
  src = c("CBS", "ESPN", "FantasyPros", "FantasySharks", "FFToday",
          "NumberFire", "RTSports", "Walterfootball"),
  pos = pos,
  season = season,
  week = week
)

# Defense in depth, now that clear_ffanalytics_cache() addresses the actual
# cause above: this doesn't prove some other cache/source edge case will
# never again leak a multi-week total into a weekly pull. `games` isn't
# populated by every source, so it alone won't catch every case - backstop
# with per-stat single-week ceilings well above any real NFL game (so a
# genuine boom week is never
# flagged); if any one stat blows past its ceiling, drop the whole row.
week_ceiling <- c(pass_yds = 600, pass_att = 70, pass_tds = 8,
                  rush_att = 45, rush_yds = 300, rush_tds = 6,
                  rec = 25, rec_yds = 350, rec_tds = 6, rec_tgt = 30)

for (p in names(raw_scrape)) {
  d <- raw_scrape[[p]]
  bad <- rep(FALSE, nrow(d))
  if ("games" %in% names(d)) bad <- bad | (!is.na(d$games) & d$games > 1)
  for (stat in names(week_ceiling)) {
    if (stat %in% names(d)) bad <- bad | (!is.na(d[[stat]]) & d[[stat]] > week_ceiling[[stat]])
  }
  if (any(bad)) {
    cat(sprintf("Dropping %d %s row(s) implausible for a single week (%s): stale season-long data, not a weekly projection.\n",
               sum(bad), p, paste(unique(d$data_src[bad]), collapse = ", ")))
    raw_scrape[[p]] <- d[!bad, ]
  }
}

saveRDS(raw_scrape, file.path("Data", sprintf("ffanalytics_raw_scrape_week%d_%d.rds", week, season)))

proj_table <- projections_table(raw_scrape)

player_lookup <- bind_rows(raw_scrape, .id = "pos_src") %>%
  distinct(id, player, team) %>%
  group_by(id) %>%
  summarise(player = first(player), team = first(team), .groups = "drop")

proj_named <- proj_table %>%
  left_join(player_lookup, by = "id") %>%
  relocate(player, team, .after = id) %>%
  arrange(pos, rank)

saveRDS(proj_named, file.path("Data", sprintf("ffanalytics_projections_week%d_%d.rds", week, season)))
write.csv(proj_named, file.path("Data", sprintf("ffanalytics_projections_week%d_%d.csv", week, season)),
          row.names = FALSE)

cat("Wrote", nrow(proj_named), "player projections for week", week, "to Data/\n")
