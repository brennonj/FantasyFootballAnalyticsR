# ESPN free-agent pool for the waiver-wire tool.
#
# Reuses espn_pos_id_map, espn_slot_id_map and player_eligible_positions from
# R Scripts/Lineup Tool/espn_lineup_data.R (expected to already be sourced by
# the caller) - free agents need the same position/slot handling as rostered
# players, and duplicating that mapping here would be one more place for the
# two to drift apart.

suppressMessages({
  library(ffscrapr)
  library(dplyr)
  library(tidyr)
  library(purrr)
  library(jsonlite)
})

# Free agents and waiver-locked players (not rostered by anyone), sorted by
# ESPN ownership so the pool comes back in roughly the order a manager would
# scan it. filterSlotIds restricts to standard offense/kicker/DST slots -
# this league runs no IDP, and ffanalytics has no IDP projections to compare
# them against anyway.
#
# limit is a single page, not a true cap: ESPN's kona_player_info accepts a
# limit up to at least 300 with no offset needed for a normal free-agent
# pool (confirmed live - a 10-team league's unrostered pool is most of the
# league, but "worth adding" candidates cluster at the top of the ownership
# sort long before 300).
espn_free_agents <- function(conn, limit = 300) {
  xff <- toJSON(list(
    players = list(
      filterStatus = list(value = list("FREEAGENT", "WAIVERS")),
      filterSlotIds = list(value = list(0, 2, 4, 6, 16, 17)),
      limit = limit,
      sortPercOwned = list(sortAsc = FALSE, sortPriority = 1)
    )
  ), auto_unbox = TRUE)

  raw <- espn_getendpoint(conn, view = "kona_player_info", x_fantasy_filter = as.character(xff))
  players <- raw$content$players
  if (length(players) == 0) return(tibble())

  tibble(entry = players) %>%
    hoist(1, player_id = "id", status = "status", "player") %>%
    hoist("player", player_name = "fullName", pos_id = "defaultPositionId",
          team_id = "proTeamId", eligible_slot_ids = "eligibleSlots",
          injury_status = "injuryStatus", injured = "injured", "ownership") %>%
    hoist("ownership", percent_owned = "percentOwned", percent_started = "percentStarted",
          percent_change = "percentChange") %>%
    transmute(
      player_id, player_name,
      pos = unname(espn_pos_id_map[as.character(pos_id)]),
      team_id, status,
      eligible_pos = purrr::map(eligible_slot_ids,
                                ~ unname(espn_slot_id_map[as.character(.x)])) %>%
                     purrr::map(player_eligible_positions),
      injury_status = coalesce(injury_status, "ACTIVE"),
      injured = coalesce(injured, FALSE),
      percent_owned = round(percent_owned, 1),
      percent_started = round(percent_started, 1),
      percent_change = round(percent_change, 2)
    )
}
