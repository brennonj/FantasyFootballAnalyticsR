# Live ESPN draft board: recommends best-available players against this
# league's real scoring rules, and tracks your roster needs as picks
# happen. Run with: shiny::runApp("R Scripts/Draft Tool/draft_board_app.R")
#
# Requires Config/espn_credentials.R (see that file for how to set it up)
# and Data/ffanalytics_raw_scrape_<season>.rds (from
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

conn <- espn_league_connect(espn_league_id, espn_season, espn_s2, espn_swid)

scoring_tbl <- ff_scoring(conn)
league_scoring <- translate_espn_scoring(scoring_tbl)
starter_positions <- ff_starter_positions(conn)
roster_max <- setNames(starter_positions$max, starter_positions$pos)

franchises <- ff_franchises(conn)
my_franchise_id <- franchises$franchise_id[franchises$franchise_name == espn_team_name]
if (length(my_franchise_id) == 0) {
  stop("espn_team_name '", espn_team_name, "' not found among franchises: ",
       paste(franchises$franchise_name, collapse = ", "))
}

raw_scrape <- readRDS(file.path(repo_root, "Data", paste0("ffanalytics_raw_scrape_", espn_season, ".rds")))

player_lookup <- bind_rows(raw_scrape, .id = "pos_src") %>%
  group_by(id) %>%
  summarise(player = first(player), team = first(team), .groups = "drop")

espn_id_crosswalk <- bind_rows(raw_scrape, .id = "pos_src") %>%
  filter(data_src == "ESPN") %>%
  distinct(id, src_id) %>%
  rename(espn_id = src_id)

proj_league <- projections_table(raw_scrape, scoring_rules = league_scoring) %>%
  filter(avg_type == "average") %>%
  left_join(player_lookup, by = "id") %>%
  left_join(espn_id_crosswalk, by = "id") %>%
  mutate(player = if_else(is.na(player) & pos == "DST", paste(team, "DST"), player)) %>%
  arrange(desc(points_vor)) %>%
  select(id, espn_id, player, pos, team, points, points_vor, floor, ceiling, tier, pos_rank)

ui <- fluidPage(
  titlePanel(paste0("Draft Board — ", espn_team_name, " (", espn_season, ")")),
  fluidRow(
    column(3, selectInput("pos_filter", "Position",
                          choices = c("All", "QB", "RB", "WR", "TE", "K", "DST"))),
    column(3, checkboxInput("hide_drafted", "Hide drafted players", TRUE)),
    column(3, actionButton("refresh", "Refresh picks now", icon = icon("rotate"))),
    column(3, strong(textOutput("draft_status")))
  ),
  fluidRow(
    column(8, DTOutput("board")),
    column(4,
      h4("Your roster"),
      tableOutput("my_roster"),
      h4("Remaining needs"),
      tableOutput("needs_table")
    )
  )
)

server <- function(input, output, session) {

  draft_raw <- reactiveVal(NULL)

  refresh_draft <- function() {
    d <- tryCatch(ff_draft(conn), error = function(e) NULL)
    draft_raw(d)
  }

  observe({
    invalidateLater(20000, session)
    refresh_draft()
  })
  observeEvent(input$refresh, refresh_draft())

  drafted_ids <- reactive({
    d <- draft_raw()
    if (is.null(d)) return(integer(0))
    d$player_id[isTRUE(d$drafted) | d$drafted %in% TRUE]
  })

  board_data <- reactive({
    ids <- drafted_ids()
    out <- proj_league %>%
      mutate(drafted = espn_id %in% ids)
    if (isTRUE(input$hide_drafted)) out <- filter(out, !drafted)
    if (input$pos_filter != "All") out <- filter(out, pos == input$pos_filter)
    out %>%
      transmute(Player = player, Pos = pos, Team = team,
                Points = round(points, 1), VOR = round(points_vor, 1),
                Floor = round(floor, 1), Ceiling = round(ceiling, 1),
                Tier = tier, `Pos Rank` = pos_rank)
  })

  output$board <- renderDT({
    datatable(board_data(), rownames = FALSE, options = list(pageLength = 20,
              order = list(list(4, "desc")))) # sort by VOR desc
  })

  output$draft_status <- renderText({
    d <- draft_raw()
    if (is.null(d)) return("Draft data unavailable")
    upcoming <- d %>% filter(!(drafted %in% TRUE)) %>% arrange(overall)
    if (nrow(upcoming) == 0) return("Draft complete")
    next_pick <- upcoming[1, ]
    my_next <- upcoming %>% filter(franchise_id == my_franchise_id) %>% slice(1)
    picks_away <- if (nrow(my_next) > 0) my_next$overall - next_pick$overall else NA
    paste0("On the clock: ", next_pick$franchise_name,
           " (pick ", next_pick$overall, ") — your next pick in ",
           ifelse(is.na(picks_away), "?", picks_away), " picks")
  })

  my_roster <- reactive({
    d <- draft_raw()
    if (is.null(d)) return(tibble())
    mine <- d %>% filter(franchise_id == my_franchise_id, drafted %in% TRUE)
    if (nrow(mine) == 0) return(tibble(Player = character(), Pos = character()))
    mine %>% transmute(Player = player_name, Pos = pos, Team = team, Round = round)
  })

  output$my_roster <- renderTable(my_roster())

  output$needs_table <- renderTable({
    mine <- my_roster()
    filled <- if (nrow(mine) == 0) c() else table(mine$Pos)
    positions <- names(roster_max)
    tibble(
      Pos = positions,
      Starters = as.integer(roster_max[positions]),
      Drafted = as.integer(sapply(positions, function(p) if (is.null(filled[[p]])) 0 else filled[[p]])),
    ) %>% mutate(Remaining = pmax(Starters - Drafted, 0))
  })
}

shinyApp(ui, server)
