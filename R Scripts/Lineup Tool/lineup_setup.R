# Shared setup for both lineup optimizer frontends: the Shiny web app
# (lineup_app.R) and the SSH/TUI snapshot poller (lineup_snapshot.R).
#
# Expects `lineup_tool_dir` and `repo_root` to already be set by the caller -
# same reasoning as Draft Tool/draft_board_setup.R (path resolution differs
# between a Shiny single-file app and a plain Rscript invocation).
#
# Produces: conn, slots, franchises, my_franchise_id, espn_team_name,
# espn_season, current_week, rosters (every franchise, this week's points
# joined on), POS_COLORS.

suppressMessages({
  library(dplyr)
  library(purrr)
  library(ffscrapr)
  library(ffanalytics)
})

source(file.path(repo_root, "Config", "espn_credentials.R"))
source(file.path(repo_root, "R Scripts", "Draft Tool", "espn_league.R"))
source(file.path(lineup_tool_dir, "espn_lineup_data.R"))

conn <- espn_league_connect(espn_league_id, espn_season, espn_s2, espn_swid)

slots <- ff_starter_positions(conn) %>%
  transmute(pos = unname(as.character(pos)), min = as.integer(min), max = as.integer(max))

franchises <- ff_franchises(conn)
my_franchise_id <- franchises$franchise_id[franchises$franchise_name == espn_team_name]
if (length(my_franchise_id) == 0) {
  stop("espn_team_name '", espn_team_name, "' not found among franchises: ",
       paste(franchises$franchise_name, collapse = ", "))
}

current_week <- espn_current_week(conn)

week_scrape_path <- file.path(repo_root, "Data",
                              sprintf("ffanalytics_raw_scrape_week%d_%d.rds", current_week, espn_season))
if (!file.exists(week_scrape_path)) {
  stop("Missing ", week_scrape_path, "\n",
       "Pull this week's projections first:\n",
       "  Rscript \"R Scripts/Projections/ffanalytics/pull_week_projections.R\" ", current_week)
}
raw_scrape <- readRDS(week_scrape_path)

league_scoring <- translate_espn_scoring(ff_scoring(conn))

weekly_points <- projections_table(raw_scrape, scoring_rules = league_scoring) %>%
  filter(avg_type == "average") %>%
  select(id, points, floor, ceiling)

# src_id comes back as character; ESPN's own player ids (player_id here, from
# espn_full_rosters()) are integers - left_join() errors on the type mismatch
# rather than silently coercing, so cast explicitly.
espn_id_crosswalk <- bind_rows(raw_scrape, .id = "pos_src") %>%
  filter(data_src == "ESPN") %>%
  distinct(id, src_id) %>%
  transmute(id, espn_id = as.integer(src_id))

player_lookup <- bind_rows(raw_scrape, .id = "pos_src") %>%
  group_by(id) %>%
  summarise(player = first(player), .groups = "drop")

# Same name-normalization fallback as Draft Tool/draft_board_setup.R: a
# handful of projected players carry no ESPN id in the scrape, so id
# matching alone would leave their points unmatched.
norm_name <- function(x) gsub("[^a-z]", "", tolower(ifelse(is.na(x), "", x)))

proj_by_espn_id <- weekly_points %>%
  left_join(espn_id_crosswalk, by = "id") %>%
  filter(!is.na(espn_id)) %>%
  distinct(espn_id, .keep_all = TRUE)

proj_by_name <- weekly_points %>%
  left_join(player_lookup, by = "id") %>%
  mutate(match_name = norm_name(player)) %>%
  filter(match_name != "") %>%
  distinct(match_name, .keep_all = TRUE)

# Re-run on every poll (fetch_rosters(), below): projections only change
# when the weekly pull is re-run, but injury designations and who's
# currently started move throughout the week, so refetching just the ESPN
# roster call and rejoining against the same points is enough to stay current
# without re-scraping projections on every refresh.
attach_points <- function(raw_rosters) {
  raw_rosters %>%
    mutate(match_name = norm_name(player_name)) %>%
    left_join(proj_by_espn_id %>% select(espn_id, points, floor, ceiling),
              by = c("player_id" = "espn_id")) %>%
    left_join(proj_by_name %>% select(match_name, points_by_name = points,
                                      floor_by_name = floor, ceiling_by_name = ceiling),
              by = "match_name") %>%
    mutate(
      points = coalesce(points, points_by_name, 0),
      floor = coalesce(floor, floor_by_name, points),
      ceiling = coalesce(ceiling, ceiling_by_name, points),
      eligible_pos = purrr::map(eligible_pos, player_eligible_positions)
    ) %>%
    select(-match_name, -points_by_name, -floor_by_name, -ceiling_by_name)
}

fetch_rosters <- function() attach_points(espn_full_rosters(conn))

rosters <- fetch_rosters()

POS_COLORS <- c(QB = "#3987e5", RB = "#d95926", WR = "#199e70",
                TE = "#c98500", K = "#d55181", DST = "#008300")
