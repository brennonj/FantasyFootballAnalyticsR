# Pure draft-state computations shared between the Shiny web app
# (draft_board_app.R) and the SSH/TUI snapshot poller (draft_board_snapshot.R).
#
# No Shiny dependency - these take plain data frames in and return plain
# lists/data frames out, so both frontends stay in sync on how a pick
# recommendation is derived without duplicating the logic.
#
# Requires recommend.R (recommend_picks, keeper_rounds, pick_order_check,
# add_implied_slot, survival_prob, roster_filled) to already be sourced.

# Draft state, reduced to what the recommender needs.
compute_state <- function(draft_raw, my_franchise_id) {
  d <- draft_raw
  if (is.null(d)) return(NULL)
  done <- d %>% filter(drafted %in% TRUE)

  # Keeper slots are assigned, not picked. Until they are filled they sit on
  # the board as undrafted, and treating them as live picks would both put a
  # recommendation on a slot nobody drafts into and shift every pick number
  # that follows. Plan against real picks only; once keepers are locked in
  # they become drafted rows and drop out of here on their own.
  kr <- keeper_rounds(d)
  pending_keepers <- d %>% filter(!(drafted %in% TRUE), round %in% kr)
  upcoming <- d %>%
    filter(!(drafted %in% TRUE), !(round %in% kr)) %>%
    arrange(overall)
  if (nrow(upcoming) == 0) return(list(complete = TRUE))

  on_clock <- upcoming[1, ]
  their_picks <- upcoming %>% filter(franchise_id == on_clock$franchise_id)
  my_picks <- upcoming %>% filter(franchise_id == my_franchise_id)

  # The pick to plan ahead for. If we're already on the clock, the hero panel
  # covers this pick, so look ahead to the one after it instead.
  i <- if (on_clock$franchise_id == my_franchise_id) 2L else 1L
  at <- function(k) if (nrow(my_picks) >= k) my_picks$overall[k] else NA_integer_

  list(
    complete = FALSE,
    done = done,
    pending_keepers = pending_keepers,
    on_clock = on_clock,
    next_pick = if (nrow(their_picks) > 1) their_picks$overall[2] else NA_integer_,
    rounds_left = nrow(their_picks),
    my_next = if (nrow(my_picks) > 0) my_picks$overall[1] else NA_integer_,
    my_rounds_left = nrow(my_picks),
    my_target_pick = at(i),
    my_target_next = at(i + 1L),
    my_target_rounds = max(nrow(my_picks) - (i - 1L), 0L)
  )
}

compute_available <- function(full_board, st, drafted_mask_fn) {
  if (is.null(st) || isTRUE(st$complete)) return(full_board)
  full_board[!drafted_mask_fn(full_board, st$done), ]
}

compute_recs <- function(available, st, slots, top_n = 6) {
  if (is.null(st) || isTRUE(st$complete)) return(NULL)
  picks_so_far <- st$done %>% select(franchise_id, pos)
  recommend_picks(
    board = available,
    picks_so_far = picks_so_far,
    franchise_id = st$on_clock$franchise_id,
    current_pick = st$on_clock$overall,
    next_pick = st$next_pick,
    slots = slots,
    rounds_left = st$rounds_left,
    top_n = top_n
  )
}

# Shortlist for our own next pick: players more likely than not to still be
# there, ranked by what they'd be worth to this roster at that point.
compute_my_targets <- function(available, st, slots, my_franchise_id, top_n = 3) {
  if (is.null(st) || isTRUE(st$complete) || is.na(st$my_target_pick)) return(NULL)

  cand <- add_implied_slot(available, st$on_clock$overall) %>%
    mutate(avail_at_target = survival_prob(implied_slot, adp_sd, st$my_target_pick)) %>%
    filter(avail_at_target >= 0.5)
  if (nrow(cand) == 0) return(NULL)

  recommend_picks(
    board = cand,
    picks_so_far = st$done %>% select(franchise_id, pos),
    franchise_id = my_franchise_id,
    current_pick = st$my_target_pick,
    next_pick = st$my_target_next,
    slots = slots,
    rounds_left = st$my_target_rounds,
    top_n = top_n
  )
}

# Startable players remaining per position: how many are still projected
# above this league's replacement level (VOR > 0).
compute_scarcity <- function(available, pos_names) {
  counts <- sapply(pos_names, function(p) sum(available$pos == p & available$points_vor > 0))
  as.list(counts)
}

compute_roster <- function(st, slots, my_franchise_id) {
  if (is.null(st) || isTRUE(st$complete)) return(NULL)
  mine <- st$done %>% filter(franchise_id == my_franchise_id) %>% arrange(overall)
  filled <- roster_filled(st$done %>% select(franchise_id, pos), my_franchise_id, slots$pos)
  list(mine = mine, filled = filled)
}

compute_order_notices <- function(draft_raw, st) {
  if (is.null(draft_raw)) return(list())
  notices <- list()

  n_pending <- if (is.null(st) || isTRUE(st$complete)) 0 else nrow(st$pending_keepers)
  if (n_pending > 0) {
    kr <- keeper_rounds(draft_raw)
    notices <- c(notices, list(list(
      title = "Keepers not assigned yet",
      detail = sprintf(
        "Round %s is the keeper round and %d of its slots are still empty. Until ESPN records who is being kept, those players still show here as available - expect the top of the board to thin out sharply once keepers lock.",
        paste(kr, collapse = ", "), n_pending)
    )))
  }

  chk <- pick_order_check(draft_raw)
  if (chk$pattern == "irregular") {
    notices <- c(notices, list(list(title = "Check draft order", detail = chk$detail)))
  }
  notices
}

# The full board annotated with drafted status and this-cycle's "% likely
# still there at your next pick" - what the main players table shows.
compute_annotated_board <- function(full_board, st, drafted_mask_fn) {
  done <- if (is.null(st) || isTRUE(st$complete)) NULL else st$done
  horizon <- if (is.null(st) || isTRUE(st$complete)) NA else
    if (is.na(st$my_next)) NA else st$my_next
  on_clock_pick <- if (is.null(st) || isTRUE(st$complete)) 1 else st$on_clock$overall

  out <- full_board %>% mutate(drafted = drafted_mask_fn(full_board, done))

  # Implied slots must be ranked across everyone still available, before any
  # display filter - ranking within a single position would place every QB as
  # though only quarterbacks were being drafted.
  idx <- which(!out$drafted)   # positional, since dual-eligible players share an id
  undrafted <- add_implied_slot(out[idx, ], on_clock_pick)
  out$Avail <- NA_real_
  if (!is.na(horizon)) {
    out$Avail[idx] <-
      round(100 * survival_prob(undrafted$implied_slot, undrafted$adp_sd, horizon))
  }
  out
}
