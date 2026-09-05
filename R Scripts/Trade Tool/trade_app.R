# Trade evaluator: verdicts on pending ESPN trade proposals, plus on-demand
# trade recommendations across the rest of the league.
#
# Run ./start-trade-evaluator.sh from the project root; it serves this at
# http://127.0.0.1:3841 and checks credentials/projections are in place first.
#
# To run it directly instead:
#   shiny::runApp("R Scripts/Trade Tool/trade_app.R", port = 3841)
#
# Requires Config/espn_credentials.R, the season projections pull and this
# week's projections pull (same as the waiver tool).

suppressMessages({
  library(shiny)
  library(dplyr)
})

# See Draft Tool/draft_board_app.R for why local = TRUE matters here.
trade_tool_dir <- getwd()
repo_root <- normalizePath(file.path(trade_tool_dir, "..", ".."))
source(file.path(trade_tool_dir, "trade_setup.R"), local = TRUE)
source(file.path(repo_root, "R Scripts", "Lineup Tool", "optimize_lineup.R"), local = TRUE)
source(file.path(trade_tool_dir, "trade_analyze.R"), local = TRUE)
source(file.path(trade_tool_dir, "trade_state.R"), local = TRUE)

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
.badge { display: inline-block; border-radius: 4px; padding: 2px 7px;
  font-size: 11px; font-weight: 700; letter-spacing: 0.04em; color: #fff; }
.verdict { display: inline-block; border-radius: 4px; padding: 2px 8px;
  font-size: 11px; font-weight: 700; letter-spacing: 0.04em; }
.verdict.ACCEPT { background: var(--good); color: #fff; }
.verdict.DECLINE { background: var(--crit); color: #fff; }
.verdict.MARGINAL { background: var(--warn); color: #201a00; }
.row-line { display: flex; align-items: center; gap: 10px; padding: 10px 0;
  border-bottom: 1px solid var(--line); }
.row-line:last-child { border-bottom: none; }
.row-name { flex: 1; font-size: 13px; }
.row-why { color: var(--muted); font-size: 11.5px; }
.row-arrow { color: var(--muted); margin: 0 6px; }
.row-score { font-variant-numeric: tabular-nums; font-weight: 650; font-size: 15px;
  width: 60px; text-align: right; }
h4 { font-size: 12px; letter-spacing: 0.1em; text-transform: uppercase;
  color: var(--muted); font-weight: 650; margin: 0 0 12px; }
.btn-default {
  background: var(--surface-2); color: var(--ink); border: 1px solid var(--border);
}
.btn-default:hover { background: #2e2e2b; color: var(--ink); }
"

pos_badge <- function(pos) {
  base <- strsplit(pos, "/", fixed = TRUE)[[1]][1]
  sprintf('<span class="badge" style="background:%s">%s</span>', POS_COLORS[[base]], pos)
}

ui <- fluidPage(
  tags$head(tags$style(HTML(app_css))),
  div(class = "topbar",
      h1("TRADE EVALUATOR"),
      span(class = "micro", paste0(espn_team_name, " · week ", current_week, " · ", espn_season)),
      span(class = "micro", style = "margin-left:auto;", uiOutput("sync_status", inline = TRUE))
  ),
  div(class = "card", h4("Pending trades involving you"), uiOutput("pending")),
  div(class = "card",
      div(style = "display:flex; align-items:center; justify-content:space-between; margin-bottom:12px;",
          h4("Trade recommendations", style = "margin:0;"),
          actionButton("find_trades", "Find trade recommendations", class = "btn-default")),
      uiOutput("recommendations"))
)

server <- function(input, output, session) {
  data <- reactiveVal(trade_data)
  last_sync <- reactiveVal(Sys.time())
  last_attempt <- reactiveVal(Sys.time())
  sync_failed <- reactiveVal(FALSE)
  recs <- reactiveVal(NULL)

  refresh <- function() {
    d <- tryCatch(fetch_trade_data(), error = function(e) NULL)
    if (is.null(d)) {
      sync_failed(TRUE)
    } else {
      data(d)
      last_sync(Sys.time())
      sync_failed(FALSE)
    }
    last_attempt(Sys.time())
  }

  # Pending-trade status and rosters move slowly; poll on the same cadence
  # as the other two tools. Full-league trade recommendations are a much
  # heavier pairwise search (see trade_analyze.R) and are deliberately
  # button-triggered instead, not recomputed on every poll.
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

  pending <- reactive(compute_pending_evaluations(data()$pending_trades, my_franchise_id,
                                                  data()$all_rosters, slots, franchises))

  output$pending <- renderUI({
    p <- pending()
    if (nrow(p) == 0) return(div(class = "micro", "No pending trades involve you right now."))
    tagList(lapply(seq_len(nrow(p)), function(i) {
      r <- p[i, ]
      div(class = "row-line",
          span(class = paste("verdict", r$verdict), r$verdict),
          div(class = "row-name",
              tags$b(paste0("Receive: ", r$receive_players)),
              span(class = "row-arrow", HTML("&rarr;")),
              paste0("Give: ", r$give_players),
              br(),
              span(class = "row-why", sprintf("vs %s · season %+.1f VOR · this week %+.1f",
                                              r$opponent, r$my_long_gain, r$my_short_gain))),
          div(class = "row-score", style = if (r$my_score > 0) "color:var(--good)" else "color:var(--crit)",
              sprintf("%+.1f", r$my_score))
      )
    }))
  })

  observeEvent(input$find_trades, {
    d <- data()
    other <- d$all_rosters %>% filter(franchise_id != my_franchise_id)
    my_roster <- d$all_rosters %>% filter(franchise_id == my_franchise_id)
    recs(compute_trade_recommendations(my_roster, other, slots, franchises, top_n = 10))
  })

  output$recommendations <- renderUI({
    r <- recs()
    if (is.null(r)) return(div(class = "micro", "Click \"Find trade recommendations\" to search the league (takes a few seconds)."))
    if (nrow(r) == 0) return(div(class = "micro", "No 1-for-1 trade improves both sides right now."))
    tagList(lapply(seq_len(nrow(r)), function(i) {
      a <- r[i, ]
      div(class = "row-line",
          HTML(pos_badge(a$give_pos)),
          div(class = "row-name",
              tags$b(paste0("Give: ", a$give_player)),
              span(class = "row-arrow", HTML("&rarr;")),
              paste0("Get: ", a$receive_player, " (", a$opponent, ")"),
              br(),
              span(class = "row-why", a$why)),
          div(class = "row-score", style = "color:var(--good)", sprintf("+%.1f", a$my_gain))
      )
    }))
  })
}

shinyApp(ui, server)
