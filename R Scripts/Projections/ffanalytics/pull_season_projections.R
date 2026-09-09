# Pulls current-season fantasy football projections using the actively
# maintained ffanalytics package (https://github.com/FantasyFootballAnalytics/ffanalytics)
# and writes an aggregated, player-named projections table to Data/.
#
# Install once: remotes::install_github("FantasyFootballAnalytics/ffanalytics")

suppressMessages({
  library(ffanalytics)
  library(dplyr)
})

season <- 2026
pos <- c("QB", "RB", "WR", "TE", "K", "DST")

# See the matching note in pull_week_projections.R: ffanalytics caches each
# source's scrape by source name alone, so a week-specific pull run shortly
# before this one can otherwise leak into this "week = 0" (rest-of-season)
# scrape too.
clear_ffanalytics_cache()

raw_scrape <- scrape_data(
  src = c("CBS", "ESPN", "FantasyPros", "FantasySharks", "FFToday",
          "NumberFire", "RTSports", "Walterfootball"),
  pos = pos,
  season = season,
  week = 0
)

saveRDS(raw_scrape, file.path("Data", paste0("ffanalytics_raw_scrape_", season, ".rds")))

proj_table <- projections_table(raw_scrape)

player_lookup <- bind_rows(raw_scrape, .id = "pos_src") %>%
  distinct(id, player, team) %>%
  group_by(id) %>%
  summarise(player = first(player), team = first(team), .groups = "drop")

proj_named <- proj_table %>%
  left_join(player_lookup, by = "id") %>%
  relocate(player, team, .after = id) %>%
  arrange(pos, rank)

saveRDS(proj_named, file.path("Data", paste0("ffanalytics_projections_", season, ".rds")))
write.csv(proj_named, file.path("Data", paste0("ffanalytics_projections_", season, ".csv")), row.names = FALSE)
