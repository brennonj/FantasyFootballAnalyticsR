# Waiver-wire add/drop recommendations, ESPN-connected.
#
# Run ./start-waiver-wire.sh from the project root; it serves this at
# http://127.0.0.1:3840 and checks credentials/projections are in place first.
#
# To run it directly instead:
#   shiny::runApp("R Scripts/Waiver Tool/waiver_app.R", port = 3840)
#
# Requires Config/espn_credentials.R,
# Data/ffanalytics_raw_scrape_<season>.rds (season pull) and
# Data/ffanalytics_raw_scrape_week<N>_<season>.rds (this week's pull).

suppressMessages({
  library(shiny)
  library(dplyr)
})

# See Draft Tool/draft_board_app.R for why local = TRUE matters here.
waiver_tool_dir <- getwd()
repo_root <- normalizePath(file.path(waiver_tool_dir, "..", ".."))
source(file.path(waiver_tool_dir, "waiver_setup.R"), local = TRUE)
source(file.path(waiver_tool_dir, "waiver_analyze.R"), local = TRUE)
source(file.path(waiver_tool_dir, "waiver_state.R"), local = TRUE)

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
.tiles { display: flex; gap: 12px; margin-bottom: 16px; flex-wrap: wrap; }
.tile { flex: 1 1 150px; background: var(--surface); border: 1px solid var(--border);
  border-radius: 10px; padding: 13px 15px; }
.tile .val { font-size: 25px; font-weight: 650; margin-top: 5px; letter-spacing: -0.015em; }
.badge { display: inline-block; border-radius: 4px; padding: 2px 7px;
  font-size: 11px; font-weight: 700; letter-spacing: 0.04em; color: #fff; }
.row-line { display: flex; align-items: center; gap: 10px; padding: 10px 0;
  border-bottom: 1px solid var(--line); }
.row-line:last-child { border-bottom: none; }
.row-name { flex: 1; font-size: 13px; }
.row-why { color: var(--muted); font-size: 11.5px; }
.row-arrow { color: var(--muted); margin: 0 6px; }
.row-score { font-variant-numeric: tabular-nums; font-weight: 650; font-size: 15px;
  width: 56px; text-align: right; color: var(--good); }
h4 { font-size: 12px; letter-spacing: 0.1em; text-transform: uppercase;
  color: var(--muted); font-weight: 650; margin: 0 0 12px; }
"

pos_badge <- function(pos) {
  sprintf('<span class="badge" style="background:%s">%s</span>', POS_COLORS[[pos]], pos)
}

ui <- fluidPage(
  tags$head(tags$style(HTML(app_css))),
  div(class = "topbar",
      h1("WAIVER WIRE"),
      span(class = "micro", paste0(espn_team_name, " · week ", current_week, " · ", espn_season)),
      span(class = "micro", style = "margin-left:auto;", uiOutput("sync_status", inline = TRUE))
  ),
  uiOutput("tiles"),
  div(class = "card", h4("Recommended adds"), uiOutput("recs"))
)

server <- function(input, output, session) {
  data <- reactiveVal(waiver_data)
  last_sync <- reactiveVal(Sys.time())
  last_attempt <- reactiveVal(Sys.time())
  sync_failed <- reactiveVal(FALSE)

  # Neither projection pull moves on its own; only ownership/injury status
  # and who's actually rostered change between manual re-pulls, so this can
  # poll slowly - same reasoning as the lineup optimizer.
  refresh <- function() {
    d <- tryCatch(fetch_waiver_data(), error = function(e) NULL)
    if (is.null(d)) {
      sync_failed(TRUE)
    } else {
      data(d)
      last_sync(Sys.time())
      sync_failed(FALSE)
    }
    last_attempt(Sys.time())
  }

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

  board <- reactive(compute_waiver_board(data()$my_roster, data()$free_agents))

  output$tiles <- renderUI({
    b <- board()
    div(class = "tiles",
      div(class = "tile", div(class = "micro", "Free agents scanned"), div(class = "val", b$pool_size)),
      div(class = "tile", div(class = "micro", "Your roster"), div(class = "val", b$roster_size)),
      div(class = "tile", div(class = "micro", "Worthwhile adds found"), div(class = "val", nrow(b$recommendations)))
    )
  })

  output$recs <- renderUI({
    r <- board()$recommendations
    if (nrow(r) == 0) return(div(class = "micro", "No free agent beats your worst rostered player right now."))
    tagList(lapply(seq_len(nrow(r)), function(i) {
      a <- r[i, ]
      div(class = "row-line",
          HTML(pos_badge(a$pos)),
          div(class = "row-name",
              tags$b(a$player_name),
              span(class = "row-arrow", HTML("&rarr;")),
              paste0("drop ", a$drop_player),
              br(),
              span(class = "row-why", a$why)),
          div(class = "row-score", paste0("+", a$score))
      )
    }))
  })
}

shinyApp(ui, server)
