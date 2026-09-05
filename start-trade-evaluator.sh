#!/usr/bin/env bash
# Launches the trade evaluator at a fixed local URL.
#
#   ./start-trade-evaluator.sh          this machine only
#   ./start-trade-evaluator.sh --lan    also reachable from phones/tablets
#
# Stop it with Ctrl-C.

set -euo pipefail

PORT=3841
APP="R Scripts/Trade Tool/trade_app.R"

HOST="${TRADE_HOST:-127.0.0.1}"
for arg in "$@"; do
  case "$arg" in
    --lan|--all) HOST="0.0.0.0" ;;
    -h|--help)
      sed -n '2,6p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) echo "unknown option: $arg (try --lan or --help)" >&2; exit 2 ;;
  esac
done
URL="http://127.0.0.1:${PORT}"

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

if lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  echo "Port $PORT is already in use - the trade evaluator may already be running at $URL" >&2
  exit 1
fi

echo "Trade evaluator  ->  $URL"

if [ "$HOST" != "127.0.0.1" ] && [ "$HOST" != "localhost" ]; then
  lan="$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || true)"
  [ -n "$lan" ] && echo "On this network ->  http://${lan}:${PORT}"
  echo
  echo "NOTE: bound to ${HOST}. This process holds a live ESPN session -"
  echo "      anything that can route here can read it, so only forward"
  echo "      port ${PORT} at the router if you mean to."
  echo
fi

echo "Connecting to ESPN and loading season + weekly projections..."
echo "(if this fails asking for a projections file, run:"
echo "   Rscript \"R Scripts/Projections/ffanalytics/pull_season_projections.R\""
echo "   Rscript \"R Scripts/Projections/ffanalytics/pull_week_projections.R\")"

exec Rscript -e "shiny::runApp('${APP}', port = ${PORT}, host = '${HOST}', launch.browser = TRUE)"
