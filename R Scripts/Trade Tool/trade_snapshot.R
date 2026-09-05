# SSH/TUI data source: polls ESPN for pending trades/roster changes and
# writes trade evaluations + recommendations out as JSON, so a separate
# process (the Textual TUI) can render them without needing R, a live ESPN
# session, or the ffanalytics/ffscrapr stack installed. Mirrors
# Waiver Tool/waiver_snapshot.R.
#
# Must be run with the repo root as the working directory - run directly with:
#   cd ~/Developer/FantasyFootball
#   Rscript "R Scripts/Trade Tool/trade_snapshot.R"
#
# Requires Config/espn_credentials.R and both projection pulls (season +
# this week), exactly like trade_app.R.

suppressMessages(library(dplyr))
suppressMessages(library(jsonlite))

repo_root <- normalizePath(getwd())
trade_tool_dir <- file.path(repo_root, "R Scripts", "Trade Tool")
if (!file.exists(file.path(trade_tool_dir, "trade_setup.R"))) {
  stop("Run this from the repo root (expected to find ",
       file.path(trade_tool_dir, "trade_setup.R"), ")")
}
source(file.path(trade_tool_dir, "trade_setup.R"), local = TRUE)
source(file.path(repo_root, "R Scripts", "Lineup Tool", "optimize_lineup.R"), local = TRUE)
source(file.path(trade_tool_dir, "trade_analyze.R"), local = TRUE)
source(file.path(trade_tool_dir, "trade_state.R"), local = TRUE)

snapshot_path <- file.path(repo_root, "Data", "trade_snapshot.json")

write_snapshot <- function(payload) {
  tmp <- paste0(snapshot_path, ".tmp")
  write(toJSON(payload, auto_unbox = TRUE, na = "null", digits = 4), tmp)
  file.rename(tmp, snapshot_path)
}

cat(sprintf("Trade snapshot poller -> %s (pending trades every 5 min, recommendations every 30 min, Ctrl-C to stop)\n",
           snapshot_path))

# The full-league pairwise search (find_trade_recommendations) is much
# heavier than a roster refresh - see trade_analyze.R - so it runs on a
# slower cadence than pending-trade evaluation rather than on every poll.
# The TUI has no interactive "search now" button the way the Shiny app does
# (no channel back to this process), so a periodic refresh is the substitute.
RECS_EVERY_N_CYCLES <- 6L  # 6 x 5 min = 30 min
cycle <- 0L
cached_recs <- tibble()

last_sync <- NULL
repeat {
  d <- tryCatch(fetch_trade_data(), error = function(e) NULL)
  sync_failed <- is.null(d)
  if (!sync_failed) last_sync <- Sys.time()

  pending_eval <- if (!sync_failed) {
    compute_pending_evaluations(d$pending_trades, my_franchise_id, d$all_rosters, slots, franchises)
  } else tibble()

  if (!sync_failed && cycle %% RECS_EVERY_N_CYCLES == 0) {
    my_roster <- d$all_rosters %>% filter(franchise_id == my_franchise_id)
    other <- d$all_rosters %>% filter(franchise_id != my_franchise_id)
    cached_recs <- compute_trade_recommendations(my_roster, other, slots, franchises, top_n = 10)
  }
  cycle <- cycle + 1L

  payload <- list(
    generated_at = format(Sys.time(), "%Y-%m-%dT%H:%M:%S%z"),
    last_sync = if (is.null(last_sync)) NULL else format(last_sync, "%Y-%m-%dT%H:%M:%S%z"),
    sync_failed = sync_failed,
    team_name = espn_team_name,
    season = espn_season,
    week = current_week,
    pending = if (nrow(pending_eval) == 0) list() else
      lapply(seq_len(nrow(pending_eval)), function(i) { r <- pending_eval[i, ]; list(
        verdict = r$verdict, opponent = r$opponent,
        give_players = r$give_players, receive_players = r$receive_players,
        my_long_gain = r$my_long_gain, my_short_gain = r$my_short_gain, my_score = r$my_score) }),
    recommendations = if (nrow(cached_recs) == 0) list() else
      lapply(seq_len(nrow(cached_recs)), function(i) { r <- cached_recs[i, ]; list(
        give_player = r$give_player, give_pos = r$give_pos,
        receive_player = r$receive_player, opponent = r$opponent,
        my_gain = r$my_gain, why = r$why) })
  )

  write_snapshot(payload)
  cat(sprintf("[%s] wrote snapshot (%s)\n", format(Sys.time(), "%H:%M:%S"),
              if (sync_failed) "SYNC FAILED - stale" else "ok"))

  Sys.sleep(300)
}
