# Shared setup for both draft board frontends: the Shiny web app
# (draft_board_app.R) and the SSH/TUI snapshot poller (draft_board_snapshot.R).
#
# Expects `draft_tool_dir` and `repo_root` to already be set by the caller,
# since path resolution differs between a Shiny single-file app (which sets
# the working directory to its own folder) and a plain Rscript invocation.
#
# Produces: conn, slots, franchises, my_franchise_id, full_board, POS_COLORS,
# norm_name, drafted_mask.

suppressMessages({
  library(dplyr)
  library(ffscrapr)
  library(ffanalytics)
})

source(file.path(repo_root, "Config", "espn_credentials.R"))
source(file.path(draft_tool_dir, "espn_league.R"))
source(file.path(draft_tool_dir, "recommend.R"))

conn <- espn_league_connect(espn_league_id, espn_season, espn_s2, espn_swid)

league_scoring <- translate_espn_scoring(ff_scoring(conn))
slots <- ff_starter_positions(conn) %>%
  transmute(pos = unname(as.character(pos)), min = as.integer(min), max = as.integer(max))

franchises <- ff_franchises(conn)
my_franchise_id <- franchises$franchise_id[franchises$franchise_name == espn_team_name]
if (length(my_franchise_id) == 0) {
  stop("espn_team_name '", espn_team_name, "' not found among franchises: ",
       paste(franchises$franchise_name, collapse = ", "))
}

raw_scrape <- readRDS(file.path(repo_root, "Data",
                                paste0("ffanalytics_raw_scrape_", espn_season, ".rds")))

player_lookup <- bind_rows(raw_scrape, .id = "pos_src") %>%
  group_by(id) %>%
  summarise(player = first(player), team = first(team), .groups = "drop")

espn_id_crosswalk <- bind_rows(raw_scrape, .id = "pos_src") %>%
  filter(data_src == "ESPN") %>%
  distinct(id, src_id) %>%
  rename(espn_id = src_id)

adp_tbl <- tryCatch(
  get_adp(sources = c("RTS", "CBS", "Yahoo", "FFC", "MFL"), metric = "adp"),
  error = function(e) tibble(id = character(), adp_avg = numeric(), adp_sd = numeric())
)

vor_baseline <- league_vor_baseline(conn, slots)

full_board <- projections_table(raw_scrape, scoring_rules = league_scoring,
                                vor_baseline = vor_baseline) %>%
  filter(avg_type == "average") %>%
  left_join(player_lookup, by = "id") %>%
  left_join(espn_id_crosswalk, by = "id") %>%
  left_join(adp_tbl[, c("id", "adp_avg", "adp_sd")], by = "id") %>%
  mutate(
    player = if_else(is.na(player) & pos == "DST", paste(team, "DST"), player),
    # Players with no ADP are effectively undrafted-caliber; park them past the
    # end of the board so the survival model treats them as near-certain to last.
    adp_avg = if_else(is.na(adp_avg), 250, adp_avg)
  ) %>%
  arrange(desc(points_vor)) %>%
  select(id, espn_id, player, pos, team, points, points_vor, floor, ceiling,
         tier, pos_rank, adp_avg, adp_sd)

POS_COLORS <- c(QB = "#3987e5", RB = "#d95926", WR = "#199e70",
                TE = "#c98500", K = "#d55181", DST = "#008300")

# A handful of projected players carry no ESPN id in the scrape, so id matching
# alone would leave them on the board after someone drafts them. Name is the
# fallback key.
norm_name <- function(x) gsub("[^a-z]", "", tolower(ifelse(is.na(x), "", x)))

full_board$match_name <- norm_name(full_board$player)

drafted_mask <- function(board, done) {
  if (is.null(done) || nrow(done) == 0) return(rep(FALSE, nrow(board)))
  board$espn_id %in% done$player_id |
    (!is.na(board$match_name) & board$match_name != "" &
       board$match_name %in% norm_name(done$player_name))
}
