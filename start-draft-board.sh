#!/usr/bin/env bash
# Launches the live draft board at a fixed local URL.
#
#   ./start-draft-board.sh
#
# Stop it with Ctrl-C.

set -euo pipefail

PORT=3838
URL="http://127.0.0.1:${PORT}"
APP="R Scripts/Draft Tool/draft_board_app.R"

# The app resolves Config/ and Data/ relative to its own location, so run from
# the project root regardless of where this was invoked.
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

if lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  echo "Port $PORT is already in use - the board may already be running at $URL" >&2
  exit 1
fi

echo "Draft board  ->  $URL"
echo "Loading league settings, draft state and ADP (~30-40s on first start)..."

exec Rscript -e "shiny::runApp('${APP}', port = ${PORT}, launch.browser = TRUE)"
