# Shared setup for both waiver-wire frontends: the Shiny web app
# (waiver_app.R) and the SSH/TUI snapshot poller (waiver_snapshot.R).
#
# Expects `waiver_tool_dir` and `repo_root` to already be set by the caller -
# same reasoning as Draft Tool/draft_board_setup.R.
#
# Produces: conn, slots, franchises, my_franchise_id, espn_team_name,
# espn_season, current_week, my_roster (my players with season VOR + this
# week's points attached), free_agents (same, for the unrostered pool),
# fetch_waiver_data() to refresh both without re-scraping projections.

suppressMessages({
  library(dplyr)
  library(purrr)
  library(ffscrapr)
  library(ffanalytics)
})

source(file.path(repo_root, "Config", "espn_credentials.R"))
source(file.path(repo_root, "R Scripts", "Draft Tool", "espn_league.R"))
source(file.path(repo_root, "R Scripts", "Lineup Tool", "espn_lineup_data.R"))
source(file.path(waiver_tool_dir, "espn_waiver_data.R"))

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
league_scoring <- translate_espn_scoring(ff_scoring(conn))

norm_name <- function(x) gsub("[^a-z]", "", tolower(ifelse(is.na(x), "", x)))

# Same id/name lookup shape as Draft Tool/draft_board_setup.R and
# Lineup Tool/lineup_setup.R: a projections_table() result plus the raw
# scrape it came from, reduced to "look up this ESPN player's numbers by
# ESPN id, falling back to normalized name."
build_lookup <- function(raw_scrape, proj) {
  # src_id comes back as character; ESPN's own player ids (player_id on
  # rosters/free agents) are integers - left_join() errors on the type
  # mismatch rather than silently coercing, so cast explicitly.
  espn_id_crosswalk <- bind_rows(raw_scrape, .id = "pos_src") %>%
    filter(data_src == "ESPN") %>%
    distinct(id, src_id) %>%
    transmute(id, espn_id = as.integer(src_id))
  player_lookup <- bind_rows(raw_scrape, .id = "pos_src") %>%
    group_by(id) %>%
    summarise(player = first(player), .groups = "drop")

  list(
    by_id = proj %>% left_join(espn_id_crosswalk, by = "id") %>%
      filter(!is.na(espn_id)) %>% distinct(espn_id, .keep_all = TRUE),
    by_name = proj %>% left_join(player_lookup, by = "id") %>%
      mutate(match_name = norm_name(player)) %>%
      filter(match_name != "") %>% distinct(match_name, .keep_all = TRUE)
  )
}

# --- season-long board (VOR): the "is this worth a roster spot all year" number ---

season_scrape_path <- file.path(repo_root, "Data",
                                sprintf("ffanalytics_raw_scrape_%d.rds", espn_season))
if (!file.exists(season_scrape_path)) {
  stop("Missing ", season_scrape_path, "\n",
       "Pull season projections first:\n",
       "  Rscript \"R Scripts/Projections/ffanalytics/pull_season_projections.R\"")
}
season_scrape <- readRDS(season_scrape_path)
vor_baseline <- league_vor_baseline(conn, slots)
season_proj <- projections_table(season_scrape, scoring_rules = league_scoring,
                                 vor_baseline = vor_baseline) %>%
  filter(avg_type == "average") %>%
  select(id, points_vor)
season_lookup <- build_lookup(season_scrape, season_proj)

# --- this week's board (points): the "is this worth starting this week" number ---

week_scrape_path <- file.path(repo_root, "Data",
                              sprintf("ffanalytics_raw_scrape_week%d_%d.rds", current_week, espn_season))
if (!file.exists(week_scrape_path)) {
  stop("Missing ", week_scrape_path, "\n",
       "Pull this week's projections first:\n",
       "  Rscript \"R Scripts/Projections/ffanalytics/pull_week_projections.R\" ", current_week)
}
week_scrape <- readRDS(week_scrape_path)
week_proj <- projections_table(week_scrape, scoring_rules = league_scoring) %>%
  filter(avg_type == "average") %>%
  select(id, points)
week_lookup <- build_lookup(week_scrape, week_proj)

# Attaches season points_vor and this week's points to any ESPN player table
# that has player_id (ESPN id) and player_name columns - rosters and free
# agents both qualify.
attach_scores <- function(df) {
  df %>%
    mutate(match_name = norm_name(player_name)) %>%
    left_join(season_lookup$by_id %>% select(espn_id, points_vor),
              by = c("player_id" = "espn_id")) %>%
    left_join(season_lookup$by_name %>% select(match_name, points_vor_bn = points_vor),
              by = "match_name") %>%
    left_join(week_lookup$by_id %>% select(espn_id, week_points = points),
              by = c("player_id" = "espn_id")) %>%
    left_join(week_lookup$by_name %>% select(match_name, week_points_bn = points),
              by = "match_name") %>%
    mutate(
      points_vor = coalesce(points_vor, points_vor_bn, 0),
      week_points = coalesce(week_points, week_points_bn, 0)
    ) %>%
    select(-match_name, -points_vor_bn, -week_points_bn)
}

# Rostered players elsewhere in the league (not mine) don't matter for "who
# should I add" - only my own roster (drop candidates) and the free-agent
# pool do. Re-run on every poll: ownership/injury status moves during the
# week even though both projection pulls are static until re-run by hand.
fetch_waiver_data <- function() {
  rosters <- espn_full_rosters(conn)
  list(
    my_roster = rosters %>% filter(franchise_id == my_franchise_id) %>% attach_scores(),
    free_agents = espn_free_agents(conn) %>% attach_scores()
  )
}

waiver_data <- fetch_waiver_data()
my_roster <- waiver_data$my_roster
free_agents <- waiver_data$free_agents

POS_COLORS <- c(QB = "#3987e5", RB = "#d95926", WR = "#199e70",
                TE = "#c98500", K = "#d55181", DST = "#008300")
