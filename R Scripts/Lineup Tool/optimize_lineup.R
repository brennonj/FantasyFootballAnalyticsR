# Weekly lineup optimizer.
#
# This is an assignment problem, not a ranking one: RB/WR/TE all compete for
# one flex slot, so "start your 9 highest-projected players" can be wrong -
# a team can be RB-rich enough that its 3rd-best RB beats every remaining WR
# for that flex spot, and greedily filling dedicated slots first would miss
# that. Solved as a small binary ILP (Rglpk) rather than by hand-rolled
# greedy logic, since the flex/dedicated-slot interaction is exactly the kind
# of overlapping-constraint problem ILP guarantees an optimum for and greedy
# heuristics silently get wrong on some rosters.
#
# Pure functions only - no Shiny, no network - mirroring Draft Tool/recommend.R.

suppressMessages(library(dplyr))
suppressMessages(library(Rglpk))

# Starter "pools" this league fills: one per dedicated position (capacity =
# min starters at that position) plus one shared flex pool (capacity = how
# many extra RB/WR/TE slots exist beyond the dedicated ones). Bench and IR
# aren't pools here - anyone not assigned to a pool is simply the bench,
# which is all that matters for "who should start."
build_slot_pools <- function(slots) {
  dedicated <- slots %>%
    filter(pos %in% c("QB", "RB", "WR", "TE", "K", "DST"), min > 0) %>%
    transmute(pool = pos, eligible = pos, capacity = min)

  flex_rows <- slots %>% filter(pos %in% c("RB", "WR", "TE"))
  flex_capacity <- if (nrow(flex_rows) == 0) 0L else max(flex_rows$max - flex_rows$min, na.rm = TRUE)

  pools <- split(dedicated, seq_len(nrow(dedicated))) %>%
    lapply(function(r) list(pool = r$pool, eligible = r$eligible, capacity = r$capacity))

  if (flex_capacity > 0) {
    pools <- c(pools, list(list(pool = "RB/WR/TE", eligible = c("RB", "WR", "TE"),
                                capacity = flex_capacity)))
  }
  pools
}

# roster: player_id, player_name, pos, eligible_pos (list-col of base
#         positions a player may start at - see player_eligible_positions()),
#         points (this week's projection, 0/NA for bye or no data)
# slots:  data.frame of pos, min, max, as returned by ff_starter_positions()
#
# Returns roster with an added `assigned_slot` column: the pool name the
# optimizer started them in, or "BE" if they didn't make the optimal lineup.
optimize_starters <- function(roster, slots) {
  roster <- roster %>% mutate(points = coalesce(points, 0), row = row_number())
  pools <- build_slot_pools(slots)

  edges <- bind_rows(lapply(pools, function(p) {
    ok <- vapply(roster$eligible_pos, function(e) any(p$eligible %in% e), logical(1))
    if (!any(ok)) return(tibble())
    tibble(row = roster$row[ok], pool = p$pool, points = roster$points[ok])
  }))

  roster$assigned_slot <- "BE"
  if (nrow(edges) == 0) return(select(roster, -row))

  n <- nrow(edges)
  player_rows <- lapply(unique(edges$row), function(r) which(edges$row == r))
  pool_rows <- lapply(pools, function(p) which(edges$pool == p$pool))

  mat <- rbind(
    do.call(rbind, lapply(player_rows, function(idx) { v <- numeric(n); v[idx] <- 1; v })),
    do.call(rbind, lapply(pool_rows,   function(idx) { v <- numeric(n); v[idx] <- 1; v }))
  )
  dir <- c(rep("<=", length(player_rows)), rep("<=", length(pool_rows)))
  rhs <- c(rep(1, length(player_rows)), vapply(pools, function(p) p$capacity, numeric(1)))

  # A tiny per-assignment bonus, negligible next to any real points gap, so
  # ties resolve toward filling every fillable slot instead of leaving one
  # empty. Without it, a slot whose only eligible player projects 0 (bye,
  # no data) is scored identically whether filled or left on the bench, and
  # the solver can leave it empty - which isn't a real option (ESPN has no
  # "leave the slot empty" lineup), and reads as a nonsense recommendation.
  sol <- Rglpk_solve_LP(obj = edges$points + 1e-4, mat = mat, dir = dir, rhs = rhs,
                        types = "B", max = TRUE)

  started <- edges[sol$solution > 0.5, ]
  roster$assigned_slot[match(started$row, roster$row)] <- started$pool
  select(roster, -row)
}

# The actual lineup ESPN has right now, by pool - so it can be compared
# against the optimizer's assignment on equal terms. A player's current_slot
# ("RB", "WR/TE", "BE", "IR", ...) IS the pool name for anyone already
# started (see espn_slot_id_map in espn_lineup_data.R), so no re-derivation
# is needed beyond excluding bench/IR.
current_assigned_slot <- function(current_slot) {
  if_else(current_slot %in% c("BE", "IR"), "BE", current_slot)
}

# Where the optimal lineup differs from what's currently set, as one row per
# pool with a real swap: bench player -> start player, and the points gained.
# Pools where the optimizer agrees with the current lineup don't appear.
compare_lineups <- function(roster_with_optimal) {
  r <- roster_with_optimal %>%
    mutate(current_pool = current_assigned_slot(current_slot))

  pools <- unique(c(r$assigned_slot, r$current_pool))
  pools <- setdiff(pools, "BE")

  out <- lapply(pools, function(p) {
    now <- r %>% filter(current_pool == p)
    opt <- r %>% filter(assigned_slot == p)
    if (nrow(now) == 0 && nrow(opt) == 0) return(NULL)
    now_id <- if (nrow(now) > 0) now$player_id[1] else NA
    opt_id <- if (nrow(opt) > 0) opt$player_id[1] else NA
    if (identical(now_id, opt_id)) return(NULL)

    tibble(
      slot = p,
      bench_player = if (nrow(now) > 0) now$player_name[1] else NA_character_,
      bench_points = if (nrow(now) > 0) now$points[1] else NA_real_,
      start_player = if (nrow(opt) > 0) opt$player_name[1] else NA_character_,
      start_points = if (nrow(opt) > 0) opt$points[1] else NA_real_,
      gain = (if (nrow(opt) > 0) opt$points[1] else 0) - (if (nrow(now) > 0) now$points[1] else 0)
    )
  })

  out <- bind_rows(out)
  if (nrow(out) == 0) return(out)
  out %>% arrange(desc(gain))
}
