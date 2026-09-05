# Weekly lineup optimizer, ESPN-connected.
#
# Run ./start-lineup-optimizer.sh from the project root; it serves this at
# http://127.0.0.1:3839 and checks credentials/projections are in place first.
#
# To run it directly instead:
#   shiny::runApp("R Scripts/Lineup Tool/lineup_app.R", port = 3839)
#
# Requires Config/espn_credentials.R and
# Data/ffanalytics_raw_scrape_week<N>_<season>.rds (from
# R Scripts/Projections/ffanalytics/pull_week_projections.R).

suppressMessages({
  library(shiny)
  library(dplyr)
})

# See Draft Tool/draft_board_app.R for why local = TRUE matters here: Shiny
# sources a single-file app into a fresh, non-global environment, and
# source()'s own default would otherwise put lineup_setup.R/lineup_state.R's
# definitions somewhere this app's own code can't see them.
lineup_tool_dir <- getwd()
repo_root <- normalizePath(file.path(lineup_tool_dir, "..", ".."))
source(file.path(lineup_tool_dir, "lineup_setup.R"), local = TRUE)
source(file.path(lineup_tool_dir, "optimize_lineup.R"), local = TRUE)
source(file.path(lineup_tool_dir, "lineup_state.R"), local = TRUE)

app_css <- "
:root {
  --plane: #0d0d0d; --surface: #1a1a19; --surface-2: #222220;
  --ink: #ffffff; --ink-2: #c3c2b7; --muted: #898781; --line: #2c2c2a;
  --border: rgba(255,255,255,0.10);
  --good: #0ca30c; --warn: #fab219; --crit: #d03b3b; --accent: #3987e5;
}
body { background: var(--plane); color: var(--ink);
  font-family: system-ui, -apple-system, 'Segoe UI', sans-serif; font-size: 14px; }
.container-fluid { max-width: 1200px; padding: 20px 26px 60px; }
.micro { font-size: 10px; letter-spacing: 0.14em; text-transform: uppercase;
  color: var(--muted); font-weight: 600; }
.topbar { display: flex; align-items: baseline; gap: 18px;
  border-bottom: 1px solid var(--line); padding-bottom: 14px; margin-bottom: 20px; }
.topbar h1 { font-size: 19px; font-weight: 650; margin: 0; letter-spacing: -0.01em; }
.livedot { width: 7px; height: 7px; border-radius: 50%; background: var(--good);
  display: inline-block; margin-right: 7px; }
.livedot.dead { background: var(--crit); }
.card { background: var(--surface); border: 1px solid var(--border);
  border-radius: 10px; padding: 16px 18px; margin-bottom: 16px; }
.notice { background: var(--surface); border: 1px solid var(--border);
  border-left: 2px solid var(--warn); border-radius: 8px;
  padding: 11px 15px; margin-bottom: 16px; font-size: 12.5px; color: var(--ink-2); }
.notice .micro { display: block; color: var(--warn); margin-bottom: 3px; }
.tiles { display: flex; gap: 12px; margin-bottom: 16px; flex-wrap: wrap; }
.tile { flex: 1 1 150px; background: var(--surface); border: 1px solid var(--border);
  border-radius: 10px; padding: 13px 15px; }
.tile .val { font-size: 25px; font-weight: 650; margin-top: 5px; letter-spacing: -0.015em; }
.tile .note { font-size: 11px; color: var(--muted); margin-top: 2px; }
.badge { display: inline-block; border-radius: 4px; padding: 2px 7px;
  font-size: 11px; font-weight: 700; letter-spacing: 0.04em; color: #fff; }
.row-line { display: flex; align-items: center; gap: 10px; padding: 8px 0;
  border-bottom: 1px solid var(--line); }
.row-line:last-child { border-bottom: none; }
.row-name { flex: 1; font-size: 13px; }
.row-sub { color: var(--muted); font-size: 11px; }
.row-val { font-variant-numeric: tabular-nums; font-weight: 650; font-size: 13px;
  width: 60px; text-align: right; }
.swap-arrow { color: var(--muted); margin: 0 6px; }
h4 { font-size: 12px; letter-spacing: 0.1em; text-transform: uppercase;
  color: var(--muted); font-weight: 650; margin: 0 0 12px; }
"

pos_badge <- function(pos) {
  col <- POS_COLORS[[strsplit(pos, "/", fixed = TRUE)[[1]][1]]]
  sprintf('<span class="badge" style="background:%s">%s</span>', col, pos)
}

ui <- fluidPage(
  tags$head(tags$style(HTML(app_css))),
  div(class = "topbar",
      h1("WEEKLY LINEUP OPTIMIZER"),
      span(class = "micro", paste0(espn_team_name, " · week ", current_week, " · ", espn_season)),
      span(class = "micro", style = "margin-left:auto;", uiOutput("sync_status", inline = TRUE))
  ),
  uiOutput("flags"),
  uiOutput("tiles"),
  fluidRow(
    column(6,
      div(class = "card", h4("Recommended swaps"), uiOutput("swaps"))
    ),
    column(6,
      div(class = "card", h4("Optimal starters"), uiOutput("starters"))
    )
  ),
  fluidRow(column(12, div(class = "card", h4("Bench"), uiOutput("bench"))))
)

server <- function(input, output, session) {
  rosters_data <- reactiveVal(rosters)
  last_sync <- reactiveVal(Sys.time())
  last_attempt <- reactiveVal(Sys.time())
  sync_failed <- reactiveVal(FALSE)

  refresh <- function() {
    d <- tryCatch(fetch_rosters(), error = function(e) NULL)
    if (is.null(d)) {
      sync_failed(TRUE)
    } else {
      rosters_data(d)
      last_sync(Sys.time())
      sync_failed(FALSE)
    }
    last_attempt(Sys.time())
  }

  # Injury designations move throughout the week; this week's points don't
  # move unless the pull script is re-run. A slow poll is enough - unlike a
  # live draft, nothing here needs 15-second freshness.
  observe({
    invalidateLater(300000, session)
    refresh()
  })
  observeEvent(input$refresh, refresh())

  output$sync_status <- renderUI({
    last_attempt()
    ts <- last_sync()
    failed <- isTRUE(sync_failed())
    if (failed) {
      mins <- floor(as.numeric(difftime(Sys.time(), ts, units = "mins")))
      return(tagList(span(class = "livedot dead"),
                     sprintf("STALE - no sync for %d min (last %s)", mins, format(ts, "%H:%M:%S"))))
    }
    tagList(span(class = "livedot"), paste("synced", format(ts, "%H:%M:%S")))
  })

  lineup <- reactive(compute_lineup(rosters_data(), my_franchise_id, slots))

  output$tiles <- renderUI({
    l <- lineup()
    if (is.null(l)) return(NULL)
    div(class = "tiles",
      div(class = "tile", div(class = "micro", "Optimal points"),
          div(class = "val", l$optimal_points)),
      div(class = "tile", div(class = "micro", "Current lineup"),
          div(class = "val", l$current_points)),
      div(class = "tile", div(class = "micro", "Gain if you make these swaps"),
          div(class = "val", style = if (l$gain > 0) "color:var(--good)" else NULL,
              paste0(if (l$gain > 0) "+" else "", l$gain)))
    )
  })

  output$flags <- renderUI({
    l <- lineup()
    if (is.null(l) || nrow(l$flags) == 0) return(NULL)
    div(class = "notice",
        span(class = "micro", "Check before kickoff"),
        tagList(lapply(seq_len(nrow(l$flags)), function(i) {
          f <- l$flags[i, ]
          div(HTML(paste0(pos_badge(f$pos), " ", f$player_name, " - ", f$note)))
        })))
  })

  output$swaps <- renderUI({
    l <- lineup()
    if (is.null(l)) return(div(class = "micro", "-"))
    if (nrow(l$swaps) == 0) return(div(class = "micro", "Your current lineup is already optimal."))
    tagList(lapply(seq_len(nrow(l$swaps)), function(i) {
      s <- l$swaps[i, ]
      div(class = "row-line",
          HTML(pos_badge(s$slot)),
          div(class = "row-name",
              if (is.na(s$bench_player)) "(empty)" else s$bench_player,
              span(class = "swap-arrow", HTML("&rarr;")),
              s$start_player),
          div(class = "row-val", style = "color:var(--good)", paste0("+", round(s$gain, 1))))
    }))
  })

  render_player_rows <- function(df) {
    if (nrow(df) == 0) return(div(class = "micro", "-"))
    tagList(lapply(seq_len(nrow(df)), function(i) {
      r <- df[i, ]
      slot_label <- if ("assigned_slot" %in% names(df)) r$assigned_slot else r$pos
      div(class = "row-line",
          HTML(pos_badge(slot_label)),
          div(class = "row-name", r$player_name,
              if (r$injury_status != "ACTIVE") span(class = "row-sub", paste0(" · ", r$injury_status))),
          div(class = "row-val", round(r$points, 1)))
    }))
  }

  output$starters <- renderUI({ l <- lineup(); if (is.null(l)) NULL else render_player_rows(l$starters) })
  output$bench <- renderUI({ l <- lineup(); if (is.null(l)) NULL else render_player_rows(l$bench) })
}

shinyApp(ui, server)
