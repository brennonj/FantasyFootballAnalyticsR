# ESPN trade data: pending proposals awaiting a response, and completed
# trade history.
#
# ff_transactions() (used elsewhere in ffscrapr) only surfaces the league's
# completed-activity feed (kona_league_communication) - it has no concept of
# a trade still sitting in someone's inbox. Pending proposals live in a
# different endpoint (mTransactions2), which is also where completed trades
# show up with full item detail, so this reads that one directly instead.
#
# NOTE ON CONFIDENCE: this league hasn't had a real trade proposed yet (built
# pre-draft), so the parsing below is verified against ESPN's confirmed
# ADD/DROP item shape (fromTeamId/toTeamId/playerId/type) - the same shape
# ESPN's own API uses for every roster-changing transaction - but not against
# a live TRADE transaction specifically. It deliberately keys off
# fromTeamId/toTeamId rather than any trade-specific `type` string, since
# that part of the schema is the one actually confirmed live. Sanity-check
# this against the first real pending trade once the season is underway.

suppressMessages({
  library(ffscrapr)
  library(dplyr)
  library(tidyr)
  library(purrr)
})

# One row per player moving in a transaction: transaction_id, type, status,
# is_pending, proposed_date, from_team, to_team, player_id.
espn_transactions <- function(conn) {
  raw <- espn_getendpoint(conn, view = "mTransactions2")
  tx <- raw$content$transactions
  if (length(tx) == 0) return(tibble())

  tibble(entry = tx) %>%
    hoist(1, transaction_id = "id", type = "type", status = "status",
          is_pending = "isPending", proposed_date = "proposedDate",
          initiating_team = "teamId", "items") %>%
    unnest(items) %>%
    hoist("items", from_team = "fromTeamId", to_team = "toTeamId",
          player_id = "playerId", item_type = "type") %>%
    transmute(transaction_id, type, status, is_pending,
             proposed_date = as.POSIXct(proposed_date / 1000, origin = "1970-01-01"),
             initiating_team, from_team, to_team, player_id, item_type)
}

# Trade proposals still awaiting a response, one row per transaction with
# the moving players nested inside - so a 3-for-2 trade is one row, not five.
espn_pending_trades <- function(conn) {
  tx <- espn_transactions(conn)
  if (nrow(tx) == 0) return(tibble())

  trades <- tx %>% filter(type == "TRADE", is_pending)
  if (nrow(trades) == 0) return(tibble())

  trades %>%
    group_by(transaction_id, initiating_team, proposed_date) %>%
    summarise(items = list(tibble(player_id, from_team, to_team)), .groups = "drop")
}

# Every team involved in a trade (the two-plus franchise ids that appear as
# either side of any item), so "does this trade involve me" is a simple
# %in% check rather than trusting which side ESPN calls the initiator.
trade_teams <- function(items) unique(c(items$from_team, items$to_team))

# Players a given franchise gives up / receives in a trade's items.
trade_gives <- function(items, franchise_id) items$player_id[items$from_team == franchise_id]
trade_receives <- function(items, franchise_id) items$player_id[items$to_team == franchise_id]
