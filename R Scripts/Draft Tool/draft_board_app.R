# Live ESPN draft board with VONA-based pick recommendations.
# Run with: shiny::runApp("R Scripts/Draft Tool/draft_board_app.R")
#
# Requires Config/espn_credentials.R and
# Data/ffanalytics_raw_scrape_<season>.rds (from
# R Scripts/Projections/ffanalytics/pull_season_projections.R).

suppressMessages({
  library(shiny)
  library(DT)
  library(dplyr)
  library(ffscrapr)
  library(ffanalytics)
})

# shiny::runApp() on a single-file app sets the working directory to this
# script's own folder, so anchor paths relative to that, not the repo root.
repo_root <- normalizePath(file.path(getwd(), "..", ".."))
source(file.path(repo_root, "Config", "espn_credentials.R"))
source(file.path(getwd(), "espn_league.R"))
source(file.path(getwd(), "recommend.R"))

conn <- espn_league_connect(espn_league_id, espn_season, espn_s2, espn_swid)

league_scoring <- translate_espn_scoring(ff_scoring(conn))
slots <- ff_starter_positions(conn) %>%
  transmute(pos = unname(as.character(pos)), min = as.integer(min), max = as.integer(max))

franchises <- ff_franchises(conn)
my_franchise_id <- franchises$franchise_id[franchises$franchise_name == espn_team_name]
if (length(my_franchise_id) == 0) {
  stop("espn_team_name '", espn_team_name, "' not found among franchises: ",
       paste(franchises$franchise_name, collapse = ", "))
}

raw_scrape <- readRDS(file.path(repo_root, "Data",
                                paste0("ffanalytics_raw_scrape_", espn_season, ".rds")))

player_lookup <- bind_rows(raw_scrape, .id = "pos_src") %>%
  group_by(id) %>%
  summarise(player = first(player), team = first(team), .groups = "drop")

espn_id_crosswalk <- bind_rows(raw_scrape, .id = "pos_src") %>%
  filter(data_src == "ESPN") %>%
  distinct(id, src_id) %>%
  rename(espn_id = src_id)

adp_tbl <- tryCatch(
  get_adp(sources = c("RTS", "CBS", "Yahoo", "FFC", "MFL"), metric = "adp"),
  error = function(e) tibble(id = character(), adp_avg = numeric(), adp_sd = numeric())
)

full_board <- projections_table(raw_scrape, scoring_rules = league_scoring) %>%
  filter(avg_type == "average") %>%
  left_join(player_lookup, by = "id") %>%
  left_join(espn_id_crosswalk, by = "id") %>%
  left_join(adp_tbl[, c("id", "adp_avg", "adp_sd")], by = "id") %>%
  mutate(
    player = if_else(is.na(player) & pos == "DST", paste(team, "DST"), player),
    # Players with no ADP are effectively undrafted-caliber; park them past the
    # end of the board so the survival model treats them as near-certain to last.
    adp_avg = if_else(is.na(adp_avg), 250, adp_avg)
  ) %>%
  arrange(desc(points_vor)) %>%
  select(id, espn_id, player, pos, team, points, points_vor, floor, ceiling,
         tier, pos_rank, adp_avg, adp_sd)

POS_COLORS <- c(QB = "#3987e5", RB = "#d95926", WR = "#199e70",
                TE = "#c98500", K = "#d55181", DST = "#008300")

# A handful of projected players carry no ESPN id in the scrape, so id matching
# alone would leave them on the board after someone drafts them. Name is the
# fallback key.
norm_name <- function(x) gsub("[^a-z]", "", tolower(ifelse(is.na(x), "", x)))

full_board$match_name <- norm_name(full_board$player)

drafted_mask <- function(board, done) {
  if (is.null(done) || nrow(done) == 0) return(rep(FALSE, nrow(board)))
  board$espn_id %in% done$player_id |
    (!is.na(board$match_name) & board$match_name != "" &
       board$match_name %in% norm_name(done$player_name))
}

app_css <- sprintf("
:root {
  --plane: #0d0d0d;
  --surface: #1a1a19;
  --surface-2: #222220;
  --ink: #ffffff;
  --ink-2: #c3c2b7;
  --muted: #898781;
  --line: #2c2c2a;
  --border: rgba(255,255,255,0.10);
  --good: #0ca30c;
  --warn: #fab219;
  --crit: #d03b3b;
  --accent: #3987e5;
}
body {
  background: var(--plane);
  color: var(--ink);
  font-family: system-ui, -apple-system, 'Segoe UI', sans-serif;
  font-size: 14px;
}
.container-fluid { max-width: 1500px; padding: 20px 26px 60px; }
.micro {
  font-size: 10px; letter-spacing: 0.14em; text-transform: uppercase;
  color: var(--muted); font-weight: 600;
}
.topbar {
  display: flex; align-items: baseline; gap: 18px;
  border-bottom: 1px solid var(--line); padding-bottom: 14px; margin-bottom: 20px;
}
.topbar h1 { font-size: 19px; font-weight: 650; margin: 0; letter-spacing: -0.01em; }
.livedot {
  width: 7px; height: 7px; border-radius: 50%%; background: var(--good);
  display: inline-block; margin-right: 7px;
  box-shadow: 0 0 0 0 rgba(12,163,12,0.7); animation: pulse 2.4s infinite;
}
@keyframes pulse {
  0%%   { box-shadow: 0 0 0 0 rgba(12,163,12,0.55); }
  70%%  { box-shadow: 0 0 0 7px rgba(12,163,12,0); }
  100%% { box-shadow: 0 0 0 0 rgba(12,163,12,0); }
}
.card {
  background: var(--surface); border: 1px solid var(--border);
  border-radius: 10px; padding: 16px 18px; margin-bottom: 16px;
}
.hero { border-left: 2px solid var(--accent); }
.hero .name {
  font-size: 34px; font-weight: 680; letter-spacing: -0.02em;
  line-height: 1.1; margin: 6px 0 2px;
}
.hero .sub { color: var(--ink-2); font-size: 13px; }
.chips { margin-top: 12px; display: flex; flex-wrap: wrap; gap: 7px; }
.chip {
  background: var(--surface-2); border: 1px solid var(--border);
  border-radius: 20px; padding: 4px 11px; font-size: 11.5px; color: var(--ink-2);
}
.badge {
  display: inline-block; border-radius: 4px; padding: 2px 7px;
  font-size: 11px; font-weight: 700; letter-spacing: 0.04em; color: #fff;
}
.tiles { display: flex; gap: 12px; margin-bottom: 16px; flex-wrap: wrap; }
.tile {
  flex: 1 1 150px; background: var(--surface); border: 1px solid var(--border);
  border-radius: 10px; padding: 13px 15px;
}
.tile .val {
  font-size: 25px; font-weight: 650; margin-top: 5px; letter-spacing: -0.015em;
}
.tile .note { font-size: 11px; color: var(--muted); margin-top: 2px; }
.meter-row { display: flex; align-items: center; gap: 10px; margin-bottom: 7px; }
.meter-label {
  width: 40px; font-size: 11px; font-weight: 650; color: var(--ink-2);
  font-variant-numeric: tabular-nums;
}
.meter-track { flex: 1; height: 9px; background: var(--surface-2); border-radius: 4px; }
.meter-fill { height: 9px; border-radius: 4px; }
.meter-val {
  width: 92px; text-align: right; font-size: 11.5px; color: var(--ink-2);
  font-variant-numeric: tabular-nums;
}
.alt-row {
  display: flex; align-items: center; gap: 10px; padding: 8px 0;
  border-bottom: 1px solid var(--line);
}
.alt-row:last-child { border-bottom: none; }
.alt-name { flex: 1; font-size: 13px; }
.alt-why { color: var(--muted); font-size: 11px; }
.alt-score {
  font-variant-numeric: tabular-nums; font-weight: 650; font-size: 13px;
  width: 52px; text-align: right;
}
h4 { font-size: 12px; letter-spacing: 0.1em; text-transform: uppercase;
     color: var(--muted); font-weight: 650; margin: 0 0 12px; }
.form-control, .selectize-input, .selectize-dropdown {
  background: var(--surface-2) !important; color: var(--ink) !important;
  border-color: var(--border) !important;
}
/* Shiny inputs ship their own block margins, which break a flex control row. */
.controls { display: flex; align-items: center; gap: 14px; margin-bottom: 4px; }
.controls > * { flex: 0 0 auto; }
.controls .form-group, .controls .shiny-input-container { margin-bottom: 0 !important; }
.controls .checkbox { margin: 0 !important; }
.controls .checkbox label { color: var(--ink-2); font-size: 12.5px; }
/* Pull DataTables' own search out of its right-floated row and inline it,
   otherwise it leaves a dead band above the header. */
.dataTables_filter {
  float: left !important; text-align: left !important; margin: 0 0 10px 0 !important;
}
.dataTables_filter label { color: var(--muted) !important; font-size: 11px; }
.dataTables_filter input {
  background: var(--surface-2) !important; color: var(--ink) !important;
  border: 1px solid var(--border) !important; border-radius: 5px;
  margin-left: 6px !important; padding: 3px 9px;
}
.btn-default {
  background: var(--surface-2); color: var(--ink); border: 1px solid var(--border);
}
.btn-default:hover { background: #2e2e2b; color: var(--ink); }
table.dataTable { color: var(--ink-2) !important; font-size: 12.5px; }
table.dataTable thead th {
  color: var(--muted) !important; border-bottom: 1px solid var(--line) !important;
  font-size: 10px; letter-spacing: 0.09em; text-transform: uppercase;
}
table.dataTable tbody td {
  border-top: 1px solid var(--line) !important;
  font-variant-numeric: tabular-nums;
}
table.dataTable tbody tr { background: transparent !important; }
table.dataTable tbody tr:hover { background: var(--surface-2) !important; }
.dataTables_wrapper .dataTables_info,
.dataTables_wrapper .dataTables_length,
.dataTables_wrapper .dataTables_filter,
.dataTables_wrapper .dataTables_paginate { color: var(--ink-2) !important; }
.dataTables_wrapper .paginate_button { color: var(--ink-2) !important; }
")

pos_badge <- function(pos) {
  sprintf('<span class="badge" style="background:%s">%s</span>',
          POS_COLORS[[pos]], pos)
}

ui <- fluidPage(
  tags$head(tags$style(HTML(app_css))),
  div(class = "topbar",
      h1("DRAFT COMMAND"),
      span(class = "micro", paste0(espn_team_name, " · ", espn_season, " · full PPR")),
      span(class = "micro", style = "margin-left:auto;",
           span(class = "livedot"), textOutput("last_sync", inline = TRUE))
  ),
  uiOutput("hero"),
  uiOutput("tiles"),
  fluidRow(
    column(7,
      div(class = "card",
          h4("Available players"),
          div(class = "controls",
              selectInput("pos_filter", NULL, width = "140px",
                          choices = c("All positions" = "All", "QB", "RB", "WR", "TE", "K", "DST")),
              checkboxInput("hide_drafted", "Hide drafted", TRUE),
              actionButton("refresh", "Sync now", class = "btn-default")
          ),
          DTOutput("board")
      )
    ),
    column(5,
      div(class = "card", h4("Next best alternatives"), uiOutput("alternatives")),
      div(class = "card", h4("Positional scarcity"), uiOutput("scarcity")),
      div(class = "card", h4("Your roster"), uiOutput("roster"))
    )
  )
)

server <- function(input, output, session) {

  draft_raw <- reactiveVal(NULL)
  last_sync <- reactiveVal(NULL)

  refresh_draft <- function() {
    d <- tryCatch(suppressWarnings(ff_draft(conn)), error = function(e) NULL)
    draft_raw(d)
    last_sync(Sys.time())
  }

  observe({
    invalidateLater(15000, session)
    refresh_draft()
  })
  observeEvent(input$refresh, refresh_draft())

  output$last_sync <- renderText({
    ts <- last_sync()
    if (is.null(ts)) "connecting" else paste("synced", format(ts, "%H:%M:%S"))
  })

  # Draft state, reduced to what the recommender needs.
  state <- reactive({
    d <- draft_raw()
    if (is.null(d)) return(NULL)
    done <- d %>% filter(drafted %in% TRUE)
    upcoming <- d %>% filter(!(drafted %in% TRUE)) %>% arrange(overall)
    if (nrow(upcoming) == 0) return(list(complete = TRUE))

    on_clock <- upcoming[1, ]
    their_picks <- upcoming %>% filter(franchise_id == on_clock$franchise_id)
    my_picks <- upcoming %>% filter(franchise_id == my_franchise_id)

    list(
      complete = FALSE,
      done = done,
      on_clock = on_clock,
      next_pick = if (nrow(their_picks) > 1) their_picks$overall[2] else NA_integer_,
      rounds_left = nrow(their_picks),
      my_next = if (nrow(my_picks) > 0) my_picks$overall[1] else NA_integer_,
      my_rounds_left = nrow(my_picks)
    )
  })

  available <- reactive({
    st <- state()
    if (is.null(st) || isTRUE(st$complete)) return(full_board)
    full_board[!drafted_mask(full_board, st$done), ]
  })

  recs <- reactive({
    st <- state()
    if (is.null(st) || isTRUE(st$complete)) return(NULL)
    picks_so_far <- st$done %>% select(franchise_id, pos)
    recommend_picks(
      board = available(),
      picks_so_far = picks_so_far,
      franchise_id = st$on_clock$franchise_id,
      current_pick = st$on_clock$overall,
      next_pick = st$next_pick,
      slots = slots,
      rounds_left = st$rounds_left,
      top_n = 6
    )
  })

  output$hero <- renderUI({
    st <- state()
    if (is.null(st)) return(div(class = "card hero", div(class = "micro", "Waiting for ESPN draft feed")))
    if (isTRUE(st$complete)) return(div(class = "card hero", div(class = "micro", "Draft complete")))
    r <- recs()
    if (is.null(r) || nrow(r) == 0) return(div(class = "card hero", div(class = "micro", "No players available")))
    top <- r[1, ]
    mine <- st$on_clock$franchise_id == my_franchise_id

    div(class = "card hero",
      div(class = "micro",
          sprintf("On the clock · %s · round %d, pick %d%s",
                  st$on_clock$franchise_name, st$on_clock$round, st$on_clock$overall,
                  if (mine) " · YOUR PICK" else "")),
      div(class = "name", top$player),
      div(class = "sub", HTML(paste(pos_badge(top$pos), "&nbsp;", top$team,
                                    "&nbsp;·&nbsp; VOR", round(top$points_vor),
                                    "&nbsp;·&nbsp; VONA", round(top$vona, 1)))),
      div(class = "chips",
          lapply(strsplit(top$why, " · ")[[1]], function(x) span(class = "chip", x)))
    )
  })

  output$tiles <- renderUI({
    st <- state()
    if (is.null(st) || isTRUE(st$complete)) return(NULL)
    av <- available()
    picks_away <- if (is.na(st$my_next)) NA else st$my_next - st$on_clock$overall
    my_filled <- roster_filled(st$done %>% select(franchise_id, pos), my_franchise_id, slots$pos)
    starters_needed <- sum(slots$min)
    starters_have <- sum(pmin(my_filled, slots$min))
    best_tier_pos <- av %>% count(pos) %>% arrange(desc(n))

    div(class = "tiles",
      div(class = "tile", div(class = "micro", "Your next pick"),
          div(class = "val", if (is.na(picks_away)) "—" else if (picks_away == 0) "NOW" else picks_away),
          div(class = "note", if (is.na(picks_away)) "no picks left" else "picks away")),
      div(class = "tile", div(class = "micro", "Starters filled"),
          div(class = "val", paste0(starters_have, "/", starters_needed)),
          div(class = "note", paste(st$my_rounds_left, "rounds remaining"))),
      div(class = "tile", div(class = "micro", "Players left"),
          div(class = "val", nrow(av)),
          div(class = "note", paste(nrow(st$done), "drafted"))),
      div(class = "tile", div(class = "micro", "Top VONA on board"),
          div(class = "val", if (is.null(recs()) || nrow(recs()) == 0) "—" else round(max(recs()$vona), 1)),
          div(class = "note", "value over next available"))
    )
  })

  output$alternatives <- renderUI({
    r <- recs()
    if (is.null(r) || nrow(r) < 2) return(div(class = "micro", "—"))
    alts <- r[-1, ]
    tagList(lapply(seq_len(nrow(alts)), function(i) {
      a <- alts[i, ]
      div(class = "alt-row",
          HTML(pos_badge(a$pos)),
          div(class = "alt-name", a$player, br(), span(class = "alt-why", a$why)),
          div(class = "alt-score", round(a$score, 1))
      )
    }))
  })

  # Startable players remaining per position: how many are still projected
  # above this league's replacement level (VOR > 0).
  output$scarcity <- renderUI({
    av <- available()
    counts <- sapply(names(POS_COLORS), function(p) sum(av$pos == p & av$points_vor > 0))
    max_n <- max(counts, 1)
    tagList(lapply(names(POS_COLORS), function(p) {
      n <- counts[[p]]
      div(class = "meter-row",
          div(class = "meter-label", p),
          div(class = "meter-track",
              div(class = "meter-fill",
                  style = sprintf("width:%.1f%%; background:%s;",
                                  100 * n / max_n, POS_COLORS[[p]]))),
          div(class = "meter-val", paste(n, "above repl."))
      )
    }))
  })

  output$roster <- renderUI({
    st <- state()
    if (is.null(st) || isTRUE(st$complete)) return(div(class = "micro", "—"))
    mine <- st$done %>% filter(franchise_id == my_franchise_id) %>% arrange(overall)
    filled <- roster_filled(st$done %>% select(franchise_id, pos), my_franchise_id, slots$pos)

    need_rows <- lapply(slots$pos, function(p) {
      have <- filled[[p]]
      need <- slots$min[slots$pos == p]
      col <- if (have >= need) "var(--good)" else "var(--warn)"
      div(class = "alt-row",
          HTML(pos_badge(p)),
          div(class = "alt-name", sprintf("%d of %d starters", have, need)),
          div(class = "alt-score", style = paste0("color:", col),
              if (have >= need) "ok" else paste0("-", need - have)))
    })

    tagList(
      if (nrow(mine) == 0) div(class = "micro", style = "margin-bottom:10px;", "No picks yet")
      else div(style = "margin-bottom:14px;",
               lapply(seq_len(nrow(mine)), function(i) {
                 div(class = "alt-row",
                     HTML(pos_badge(mine$pos[i])),
                     div(class = "alt-name", mine$player_name[i]),
                     div(class = "alt-score", paste0("R", mine$round[i])))
               })),
      need_rows
    )
  })

  output$board <- renderDT({
    st <- state()
    done <- if (is.null(st) || isTRUE(st$complete)) NULL else st$done
    horizon <- if (is.null(st) || isTRUE(st$complete)) NA else
      if (is.na(st$my_next)) NA else st$my_next

    out <- full_board %>% mutate(drafted = drafted_mask(full_board, done))
    if (isTRUE(input$hide_drafted)) out <- filter(out, !drafted)
    if (input$pos_filter != "All") out <- filter(out, pos == input$pos_filter)

    out <- out %>%
      mutate(
        Avail = if (is.na(horizon)) NA_real_ else
          round(100 * survival_prob(adp_avg, adp_sd, horizon))
      ) %>%
      transmute(
        Player = player,
        Pos = vapply(pos, pos_badge, character(1)),
        Tm = team,
        Pts = round(points, 1),
        VOR = round(points_vor, 1),
        ADP = round(adp_avg, 1),
        `Avail %` = Avail,
        Tier = tier
      )

    datatable(out, rownames = FALSE, escape = FALSE,
              options = list(pageLength = 15, order = list(list(4, "desc")),
                             lengthChange = FALSE,
                             language = list(search = "",
                                             searchPlaceholder = "Filter players")))
  })
}

shinyApp(ui, server)
