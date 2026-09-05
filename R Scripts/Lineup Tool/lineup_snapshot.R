# SSH/TUI data source: polls ESPN for roster/injury changes and writes the
# computed optimal lineup out as JSON, so a separate process (the Textual
# TUI) can render it without needing R, a live ESPN session, or the
# ffanalytics/ffscrapr stack installed. Mirrors Draft Tool/draft_board_snapshot.R.
#
# Must be run with the repo root as the working directory - run directly with:
#   cd ~/Developer/FantasyFootball
#   Rscript "R Scripts/Lineup Tool/lineup_snapshot.R"
#
# Requires Config/espn_credentials.R and this week's
# Data/ffanalytics_raw_scrape_week<N>_<season>.rds, exactly like lineup_app.R -
# this sources the same lineup_setup.R/optimize_lineup.R/lineup_state.R, so
# both frontends compute the optimal lineup identically.

suppressMessages(library(dplyr))
suppressMessages(library(jsonlite))

# Not derived from commandArgs(): Rscript's own --file= wrapper mis-encodes
# spaces in paths like "R Scripts/Lineup Tool" - a plain cwd-relative path
# avoids that entirely (see the same note in draft_board_snapshot.R).
repo_root <- normalizePath(getwd())
lineup_tool_dir <- file.path(repo_root, "R Scripts", "Lineup Tool")
if (!file.exists(file.path(lineup_tool_dir, "lineup_setup.R"))) {
  stop("Run this from the repo root (expected to find ",
       file.path(lineup_tool_dir, "lineup_setup.R"), ")")
}
source(file.path(lineup_tool_dir, "lineup_setup.R"), local = TRUE)
source(file.path(lineup_tool_dir, "optimize_lineup.R"), local = TRUE)
source(file.path(lineup_tool_dir, "lineup_state.R"), local = TRUE)

snapshot_path <- file.path(repo_root, "Data", "lineup_snapshot.json")

# Written atomically (tmp file + rename), same reasoning as the draft board
# poller: the TUI polls this file on its own schedule and must never read a
# half-written one mid-write.
write_snapshot <- function(payload) {
  tmp <- paste0(snapshot_path, ".tmp")
  write(toJSON(payload, auto_unbox = TRUE, na = "null", digits = 4), tmp)
  file.rename(tmp, snapshot_path)
}

player_row <- function(r, slot_field) {
  list(player = r$player_name, pos = r[[slot_field]], points = round(r$points, 1),
       injury_status = r$injury_status)
}

cat(sprintf("Lineup snapshot poller -> %s (every 5 min, Ctrl-C to stop)\n", snapshot_path))

last_sync <- NULL
repeat {
  d <- tryCatch(fetch_rosters(), error = function(e) NULL)
  sync_failed <- is.null(d)
  if (!sync_failed) last_sync <- Sys.time()

  l <- if (!sync_failed) compute_lineup(d, my_franchise_id, slots) else NULL

  payload <- list(
    generated_at = format(Sys.time(), "%Y-%m-%dT%H:%M:%S%z"),
    last_sync = if (is.null(last_sync)) NULL else format(last_sync, "%Y-%m-%dT%H:%M:%S%z"),
    sync_failed = sync_failed,
    team_name = espn_team_name,
    season = espn_season,
    week = current_week,
    tiles = if (is.null(l)) NULL else list(
      optimal_points = l$optimal_points, current_points = l$current_points, gain = l$gain
    ),
    flags = if (is.null(l) || nrow(l$flags) == 0) list() else
      lapply(seq_len(nrow(l$flags)), function(i) list(
        player = l$flags$player_name[i], pos = l$flags$pos[i], note = l$flags$note[i])),
    swaps = if (is.null(l) || nrow(l$swaps) == 0) list() else
      lapply(seq_len(nrow(l$swaps)), function(i) { s <- l$swaps[i, ]; list(
        slot = s$slot,
        bench_player = if (is.na(s$bench_player)) NULL else s$bench_player,
        bench_points = if (is.na(s$bench_points)) NULL else round(s$bench_points, 1),
        start_player = s$start_player, start_points = round(s$start_points, 1),
        gain = round(s$gain, 1)) }),
    starters = if (is.null(l)) list() else
      lapply(seq_len(nrow(l$starters)), function(i) player_row(l$starters[i, ], "assigned_slot")),
    bench = if (is.null(l)) list() else
      lapply(seq_len(nrow(l$bench)), function(i) player_row(l$bench[i, ], "pos"))
  )

  write_snapshot(payload)
  cat(sprintf("[%s] wrote snapshot (%s)\n", format(Sys.time(), "%H:%M:%S"),
              if (sync_failed) "SYNC FAILED - stale" else "ok"))

  Sys.sleep(300)
}
