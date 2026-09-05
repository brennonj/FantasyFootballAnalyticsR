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

raw_scrape <- scrape_data(
  src = c("CBS", "ESPN", "FantasyPros", "FantasySharks", "FFToday",
          "NumberFire", "RTSports", "Walterfootball"),
  pos = pos,
  season = season,
  week = week
)

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
