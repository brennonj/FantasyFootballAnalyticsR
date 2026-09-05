# SSH/TUI data source: polls ESPN for ownership/roster changes and writes the
# computed waiver-wire recommendations out as JSON, so a separate process
# (the Textual TUI) can render them without needing R, a live ESPN session,
# or the ffanalytics/ffscrapr stack installed. Mirrors
# Lineup Tool/lineup_snapshot.R.
#
# Must be run with the repo root as the working directory - run directly with:
#   cd ~/Developer/FantasyFootball
#   Rscript "R Scripts/Waiver Tool/waiver_snapshot.R"
#
# Requires Config/espn_credentials.R and both projection pulls (season +
# this week), exactly like waiver_app.R - this sources the same
# waiver_setup.R/waiver_analyze.R/waiver_state.R, so both frontends compute
# recommendations identically.

suppressMessages(library(dplyr))
suppressMessages(library(jsonlite))

repo_root <- normalizePath(getwd())
waiver_tool_dir <- file.path(repo_root, "R Scripts", "Waiver Tool")
if (!file.exists(file.path(waiver_tool_dir, "waiver_setup.R"))) {
  stop("Run this from the repo root (expected to find ",
       file.path(waiver_tool_dir, "waiver_setup.R"), ")")
}
source(file.path(waiver_tool_dir, "waiver_setup.R"), local = TRUE)
source(file.path(waiver_tool_dir, "waiver_analyze.R"), local = TRUE)
source(file.path(waiver_tool_dir, "waiver_state.R"), local = TRUE)

snapshot_path <- file.path(repo_root, "Data", "waiver_snapshot.json")

write_snapshot <- function(payload) {
  tmp <- paste0(snapshot_path, ".tmp")
  write(toJSON(payload, auto_unbox = TRUE, na = "null", digits = 4), tmp)
  file.rename(tmp, snapshot_path)
}

cat(sprintf("Waiver wire snapshot poller -> %s (every 5 min, Ctrl-C to stop)\n", snapshot_path))

last_sync <- NULL
repeat {
  d <- tryCatch(fetch_waiver_data(), error = function(e) NULL)
  sync_failed <- is.null(d)
  if (!sync_failed) last_sync <- Sys.time()

  b <- if (!sync_failed) compute_waiver_board(d$my_roster, d$free_agents) else NULL

  payload <- list(
    generated_at = format(Sys.time(), "%Y-%m-%dT%H:%M:%S%z"),
    last_sync = if (is.null(last_sync)) NULL else format(last_sync, "%Y-%m-%dT%H:%M:%S%z"),
    sync_failed = sync_failed,
    team_name = espn_team_name,
    season = espn_season,
    week = current_week,
    pool_size = if (is.null(b)) NA else b$pool_size,
    roster_size = if (is.null(b)) NA else b$roster_size,
    recommendations = if (is.null(b) || nrow(b$recommendations) == 0) list() else
      lapply(seq_len(nrow(b$recommendations)), function(i) { r <- b$recommendations[i, ]; list(
        player = r$player_name, pos = r$pos,
        drop_player = r$drop_player, drop_pos = r$drop_pos,
        score = r$score, why = r$why) })
  )

  write_snapshot(payload)
  cat(sprintf("[%s] wrote snapshot (%s)\n", format(Sys.time(), "%H:%M:%S"),
              if (sync_failed) "SYNC FAILED - stale" else "ok"))

  Sys.sleep(300)
}
