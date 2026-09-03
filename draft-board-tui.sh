#!/usr/bin/env bash
# Launches the live draft board as a terminal UI - the same recommendations
# as start-draft-board.sh's web board, but with no HTTP server, so it works
# over a plain SSH session (no port forwarding, no browser, no security
# software flagging a bare-HTTP connection to your public IP).
#
#   ./draft-board-tui.sh
#
# Under the hood: an R process polls ESPN every 15s (same as the web board)
# and writes Data/draft_board_snapshot.json; a Python/Textual app renders
# that file and re-reads it every 2s. Stop with Ctrl-C or 'q' - this also
# stops the R poller.
#
# To use this from another machine, SSH in and run this script normally:
#   ssh you@this-mac "cd ~/Developer/FantasyFootball && ./draft-board-tui.sh"
# (interactively - not from a non-interactive `ssh host cmd` pipe, since the
# TUI needs a real terminal).

set -euo pipefail

# The app resolves Config/, Data/ and its own scripts relative to the repo
# root, so run from there regardless of where this was invoked.
cd "$(dirname "${BASH_SOURCE[0]}")"

if [ ! -f "Config/espn_credentials.R" ]; then
  cat >&2 <<'MSG'
Missing Config/espn_credentials.R

It is git-ignored on purpose, so it does not survive a fresh clone or travel
with a merge - copy it across, or recreate it with:

  espn_league_id <- <your league id>
  espn_season    <- <season>
  espn_s2        <- "<espn_s2 cookie>"
  espn_swid      <- "{<SWID cookie>}"
  espn_team_name <- "<your team name>"
MSG
  exit 1
fi

season="$(sed -n 's/^espn_season[[:space:]]*<-[[:space:]]*\([0-9]\{4\}\).*/\1/p' \
  Config/espn_credentials.R | head -1)"

if [ -n "$season" ] && [ ! -f "Data/ffanalytics_raw_scrape_${season}.rds" ]; then
  cat >&2 <<MSG
Missing Data/ffanalytics_raw_scrape_${season}.rds

Pull the projections first (a few minutes - it scrapes every source):

  Rscript "R Scripts/Projections/ffanalytics/pull_season_projections.R"
MSG
  exit 1
fi

VENV="Draft Board TUI/.venv"
if [ ! -x "$VENV/bin/python" ]; then
  echo "Setting up the TUI's Python environment (first run only)..." >&2
  python3 -m venv "$VENV"
  "$VENV/bin/pip" install --quiet --upgrade pip
  "$VENV/bin/pip" install --quiet -r "Draft Board TUI/requirements.txt"
fi

SNAPSHOT="Data/draft_board_snapshot.json"
rm -f "$SNAPSHOT"

Rscript "R Scripts/Draft Tool/draft_board_snapshot.R" &
POLLER_PID=$!
trap 'kill "$POLLER_PID" 2>/dev/null || true' EXIT

echo "Starting draft board TUI - first sync takes ~30-40s (ESPN connect + projections)..." >&2

exec "$VENV/bin/python" "Draft Board TUI/draft_board_tui.py" "$SNAPSHOT"
