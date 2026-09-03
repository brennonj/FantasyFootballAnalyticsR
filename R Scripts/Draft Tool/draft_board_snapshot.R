# SSH/TUI data source: polls the live ESPN draft feed on the same 15s cadence
# as the Shiny board and writes the full board + recommendations out as JSON,
# so a separate process (the Textual TUI) can render them without needing R,
# a live ESPN session, or the ffanalytics/ffscrapr stack installed.
#
# Must be run with the repo root as the working directory (draft-board-tui.sh
# does this, the same way start-draft-board.sh does for the Shiny app) - run
# directly instead with:
#   cd ~/Developer/FantasyFootball
#   Rscript "R Scripts/Draft Tool/draft_board_snapshot.R"
#
# Requires Config/espn_credentials.R and
# Data/ffanalytics_raw_scrape_<season>.rds, exactly like draft_board_app.R -
# this sources the same draft_board_setup.R and draft_state.R, so both
# frontends compute picks identically.

suppressMessages(library(dplyr))
suppressMessages(library(jsonlite))

# Not derived from commandArgs(): Rscript's own wrapper mis-encodes spaces in
# --file= paths (turns them into literal "~+~"), which corrupts a path like
# "R Scripts/Draft Tool" - a plain cwd-relative path avoids that entirely.
repo_root <- normalizePath(getwd())
draft_tool_dir <- file.path(repo_root, "R Scripts", "Draft Tool")
if (!file.exists(file.path(draft_tool_dir, "draft_board_setup.R"))) {
  stop("Run this from the repo root (expected to find ",
       file.path(draft_tool_dir, "draft_board_setup.R"), ")")
}
source(file.path(draft_tool_dir, "draft_board_setup.R"), local = TRUE)
source(file.path(draft_tool_dir, "draft_state.R"), local = TRUE)

snapshot_path <- file.path(repo_root, "Data", "draft_board_snapshot.json")

# Written atomically (tmp file + rename) so the TUI, which polls this file on
# its own schedule, never reads a half-written snapshot mid-write.
write_snapshot <- function(payload) {
  tmp <- paste0(snapshot_path, ".tmp")
  write(toJSON(payload, auto_unbox = TRUE, na = "null", digits = 4), tmp)
  file.rename(tmp, snapshot_path)
}

reason_chips <- function(why) {
  if (is.null(why) || is.na(why) || why == "") return(list())
  strsplit(why, " · ")[[1]]
}

pick_row <- function(row) {
  list(player = row$player, pos = row$pos, team = row$team,
       points_vor = round(row$points_vor, 1), vona = round(row$vona, 1),
       score = round(row$score, 1), why = reason_chips(row$why))
}

target_row <- function(row) {
  sub <- Filter(function(s) !grepl("gone by pick", s), reason_chips(row$why))
  list(player = row$player, pos = row$pos, points_vor = round(row$points_vor, 1),
       avail_pct = round(100 * row$avail_at_target), why = sub)
}

board_row <- function(row) {
  list(player = row$player, pos = row$pos, team = row$team,
       points = round(row$points, 1), points_vor = round(row$points_vor, 1),
       adp_avg = round(row$adp_avg, 1), tier = row$tier,
       avail_pct = if (is.na(row$Avail)) NA else row$Avail,
       drafted = isTRUE(row$drafted))
}

cat(sprintf("Draft board snapshot poller -> %s (every 15s, Ctrl-C to stop)\n", snapshot_path))

# Mirrors draft_board_app.R's refresh_draft(): a failed poll keeps the last
# good state rather than blanking the snapshot, but the timestamp only
# advances on success, so an expired ESPN cookie shows up as visibly stale
# rather than looking like a healthy feed.
last_sync <- NULL
repeat {
  d <- tryCatch(suppressWarnings(ff_draft(conn)), error = function(e) NULL)
  sync_failed <- is.null(d)
  if (!sync_failed) last_sync <- Sys.time()

  st <- if (!is.null(d)) compute_state(d, my_franchise_id) else NULL
  complete <- isTRUE(st$complete)
  av <- compute_available(full_board, st, drafted_mask)
  recs <- compute_recs(av, st, slots, top_n = 6)
  my_targets <- compute_my_targets(av, st, slots, my_franchise_id, top_n = 3)
  roster <- compute_roster(st, slots, my_franchise_id)
  scarcity <- compute_scarcity(av, names(POS_COLORS))
  notices <- compute_order_notices(d, st)
  board <- compute_annotated_board(full_board, st, drafted_mask) %>% arrange(desc(points_vor))

  filled <- if (!is.null(roster)) roster$filled else setNames(as.list(rep(0, nrow(slots))), slots$pos)
  starters_needed <- sum(slots$min)
  starters_have <- sum(pmin(unlist(filled)[slots$pos], slots$min))

  payload <- list(
    generated_at = format(Sys.time(), "%Y-%m-%dT%H:%M:%S%z"),
    last_sync = if (is.null(last_sync)) NULL else format(last_sync, "%Y-%m-%dT%H:%M:%S%z"),
    sync_failed = sync_failed,
    team_name = espn_team_name,
    season = espn_season,
    complete = complete,
    notices = lapply(notices, function(n) list(title = n$title, detail = n$detail)),
    on_clock = if (is.null(st) || complete) NULL else list(
      franchise_name = st$on_clock$franchise_name,
      round = st$on_clock$round, overall = st$on_clock$overall,
      mine = st$on_clock$franchise_id == my_franchise_id
    ),
    hero = if (is.null(recs) || nrow(recs) == 0) NULL else pick_row(recs[1, ]),
    alternatives = if (is.null(recs) || nrow(recs) < 2) list() else
      lapply(seq_len(nrow(recs) - 1), function(i) pick_row(recs[-1, ][i, ])),
    my_target_pick = if (is.null(st) || complete) NA else st$my_target_pick,
    my_targets = if (is.null(my_targets)) list() else
      lapply(seq_len(nrow(my_targets)), function(i) target_row(my_targets[i, ])),
    tiles = if (is.null(st) || complete) NULL else list(
      picks_away = if (is.na(st$my_next)) NA else st$my_next - st$on_clock$overall,
      starters_have = starters_have, starters_needed = starters_needed,
      rounds_left = st$my_rounds_left,
      players_left = nrow(av), drafted_count = nrow(st$done),
      top_vona = if (is.null(recs) || nrow(recs) == 0) NA else round(max(recs$vona), 1)
    ),
    scarcity = scarcity,
    roster = if (is.null(roster)) list(mine = list(), filled = list()) else list(
      mine = lapply(seq_len(nrow(roster$mine)), function(i) list(
        player = roster$mine$player_name[i], pos = roster$mine$pos[i],
        round = roster$mine$round[i])),
      filled = as.list(setNames(as.integer(unlist(filled)[slots$pos]), slots$pos))
    ),
    slots = as.list(setNames(as.integer(slots$min), slots$pos)),
    board = lapply(seq_len(nrow(board)), function(i) board_row(board[i, ]))
  )

  write_snapshot(payload)
  cat(sprintf("[%s] wrote snapshot (%s)\n", format(Sys.time(), "%H:%M:%S"),
              if (sync_failed) "SYNC FAILED - stale" else "ok"))

  Sys.sleep(15)
}
