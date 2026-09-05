#!/usr/bin/env bash
# Launches the weekly lineup optimizer as a terminal UI - the same
# recommendations as start-lineup-optimizer.sh's web app, but with no HTTP
# server, so it works over a plain SSH session.
#
#   ./lineup-optimizer-tui.sh
#
# Under the hood: an R process polls ESPN every 5 min and writes
# Data/lineup_snapshot.json; a Python/Textual app renders that file and
# re-reads it every 2s. Stop with Ctrl-C or 'q' - this also stops the poller.
#
# To use this from another machine, SSH in and run this script normally:
#   ssh you@this-mac "cd ~/Developer/FantasyFootball && ./lineup-optimizer-tui.sh"
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

VENV="Lineup Optimizer TUI/.venv"
if [ ! -x "$VENV/bin/python" ]; then
  echo "Setting up the TUI's Python environment (first run only)..." >&2
  python3 -m venv "$VENV"
  "$VENV/bin/pip" install --quiet --upgrade pip
  "$VENV/bin/pip" install --quiet -r "Lineup Optimizer TUI/requirements.txt"
fi

SNAPSHOT="Data/lineup_snapshot.json"
rm -f "$SNAPSHOT"

echo "Connecting to ESPN and loading this week's projections..." >&2
echo "(if this fails asking for a weekly projections file, run:" >&2
echo "   Rscript \"R Scripts/Projections/ffanalytics/pull_week_projections.R\")" >&2

Rscript "R Scripts/Lineup Tool/lineup_snapshot.R" &
POLLER_PID=$!
trap 'kill "$POLLER_PID" 2>/dev/null || true' EXIT

exec "$VENV/bin/python" "Lineup Optimizer TUI/lineup_tui.py" "$SNAPSHOT"
