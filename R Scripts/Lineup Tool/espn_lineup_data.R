# ESPN data access for the weekly lineup optimizer.
#
# Reuses espn_league_connect() from the Draft Tool rather than duplicating
# it - both tools authenticate to the same league the same way. Everything
# else here is lineup-specific: which week it is, and what's actually on
# each roster right now (including which slot ESPN currently has each player
# in, and their injury status) - none of which the draft tool needs, so none
# of it lives in espn_league.R.
#
# ff_rosters() (used by the draft tool) deliberately isn't reused here: it
# hoists player/position/team out of ESPN's raw mRoster response but drops
# lineupSlotId and injuryStatus, which is exactly what start/sit decisions
# turn on. So this parses that response itself, the same way ff_rosters does
# internally (tidyr::hoist over teams -> roster -> entries).

suppressMessages({
  library(ffscrapr)
  library(dplyr)
  library(tidyr)
  library(purrr)
})

# ESPN's lineup slot ids -> names, for the slot types a standard (non-IDP)
# league actually uses. Stable across leagues/seasons - this is ESPN's fixed
# internal enum, not something read off any one league's settings.
espn_slot_id_map <- c(
  `0` = "QB", `2` = "RB", `3` = "RB/WR", `4` = "WR", `5` = "WR/TE",
  `6` = "TE", `7` = "OP", `16` = "DST", `17` = "K",
  `20` = "BE", `21` = "IR", `23` = "RB/WR/TE"
)

espn_pos_id_map <- c(`1` = "QB", `2` = "RB", `3` = "WR", `4` = "TE", `5` = "K", `16` = "DST")

# A player's ESPN eligibleSlots always includes every compound flex slot
# their default position could theoretically fill in *some* league (e.g. a
# WR is always flagged eligible for ESPN's "RB/WR" and "WR/TE" two-way flex
# codes, on top of "WR" itself) - regardless of whether this league actually
# has that slot. Splitting a compound name like "RB/WR/TE" into its base
# parts and unioning them into the player's eligible set (the previous
# approach here) therefore makes every flex-eligible RB/WR/TE player look
# eligible for *all three* dedicated pools, not just the shared flex pool -
# a real WR would get placed in the dedicated RB pool. Single-position names
# ("RB") are kept as-is; the one compound name this tool actually models a
# pool for ("RB/WR/TE", build_slot_pools' flex pool) is kept as its own
# pseudo-position so it can be matched against that pool by exact name
# instead. Other compounds (ESPN's narrower two-way flex codes, OP) are
# dropped - this tool has no pool for them, so splitting them the old way
# only introduced false positional eligibility.
# Slot ids outside espn_slot_id_map (IDP/taxi-squad slots this league doesn't
# use) come in as NA rather than a name - drop those rather than leaking a
# literal "NA" into the position set.
player_eligible_positions <- function(eligible_slot_names) {
  parts <- eligible_slot_names[!is.na(eligible_slot_names) &
                                  (!grepl("/", eligible_slot_names, fixed = TRUE) |
                                     eligible_slot_names == "RB/WR/TE")]
  unique(setdiff(parts, c("BE", "IR")))
}

# Current NFL/fantasy week per ESPN. currentMatchupPeriod is the fantasy
# week ESPN itself is using for lineups right now (unlike scoringPeriodId,
# which is 0 before the season's first game has been scored).
espn_current_week <- function(conn) {
  raw <- espn_getendpoint(conn, view = "mStatus")
  as.integer(raw$content$status$currentMatchupPeriod)
}

# Full roster detail for every franchise: who's on which team, which slot
# ESPN currently has them in, and their injury designation - the inputs the
# optimizer needs that ff_rosters() doesn't expose.
#
# Returns one row per rostered player: franchise_id, franchise_name,
# player_id, player_name, pos (default position), team, eligible_pos
# (character vector column, e.g. c("RB","WR","TE","BE","IR") for a
# flex-eligible RB), current_slot, injury_status, injured (logical).
espn_full_rosters <- function(conn) {
  franchises <- ff_franchises(conn) %>% select(franchise_id, franchise_name)

  raw <- espn_getendpoint(conn, view = "mRoster")
  if (isFALSE(raw$content$draftDetail$drafted)) {
    warning("ESPN league has not drafted yet - no rosters to read.", call. = FALSE)
    return(tibble())
  }

  raw$content %>%
    purrr::pluck("teams") %>%
    tibble() %>%
    hoist(1, franchise_id = "id", "roster") %>%
    hoist("roster", "entries") %>%
    select(-roster) %>%
    unnest(entries) %>%
    hoist("entries",
          player_id = "playerId", current_slot_id = "lineupSlotId",
          player_data = "playerPoolEntry") %>%
    hoist("player_data", "player") %>%
    hoist("player",
          player_name = "fullName", pos_id = "defaultPositionId",
          team_id = "proTeamId", eligible_slot_ids = "eligibleSlots",
          injury_status = "injuryStatus", injured = "injured") %>%
    transmute(
      franchise_id,
      player_id,
      player_name,
      pos = unname(espn_pos_id_map[as.character(pos_id)]),
      team_id,
      current_slot = unname(espn_slot_id_map[as.character(current_slot_id)]),
      eligible_pos = purrr::map(eligible_slot_ids,
                                ~ unname(espn_slot_id_map[as.character(.x)])),
      # hoist() leaves injury_status as a list column when some entries are
      # structurally absent from ESPN's JSON (NULL, not NA) rather than
      # simplifying to an atomic vector - coalesce() doesn't reach inside a
      # list column, so normalize element-by-element first.
      injury_status = purrr::map_chr(injury_status, function(x) {
        val <- if (length(x) == 0) NA_character_ else as.character(x)
        if (is.na(val)) "ACTIVE" else val
      }),
      injured = coalesce(injured, FALSE)
    ) %>%
    left_join(franchises, by = "franchise_id") %>%
    relocate(franchise_name, .after = franchise_id)
}
