# Trial publication finder and data collection app.
#
# Tab 1: search ClinicalTrials.gov, link trials to their results papers, and
#        download the DOI list as Excel.
# Tab 2: send the DOI list, an output template and a codebook to the
#        data-collection agent and download the filled-in template.
#
# Functions live in R/ (loaded automatically by Shiny). Long steps run in a
# background R process so one user's run doesn't freeze the app for others.

library(shiny)
library(bslib)
library(promises)

future::plan(future::multisession, workers = 2)

APP_DIR <- normalizePath(".")
options(app_dir = APP_DIR)
DEFAULT_TEMPLATE <- file.path(APP_DIR, "defaults", "output_template.xlsx")
DEFAULT_INSTRUCTIONS <- file.path(APP_DIR, "defaults", c("agent_instructions.txt", "exclusion_rules.txt"))

# Run inside the background process: load the app's functions there too.
load_app_functions <- function(app_dir) {
  options(app_dir = app_dir)
  for (f in list.files(file.path(app_dir, "R"), pattern = "\\.R$", full.names = TRUE)) source(f, local = FALSE)
}

read_instructions <- function() {
  files <- DEFAULT_INSTRUCTIONS[file.exists(DEFAULT_INSTRUCTIONS)]
  paste(vapply(files, function(f) paste(readLines(f, warn = FALSE), collapse = "\n"), character(1)),
        collapse = "\n\n")
}

## ---- UI -----------------------------------------------------------------

progress_card <- function(id) {
  # fillable = FALSE stops the card from squeezing the bar to zero height
  # when the log is long.
  card(
    fill = FALSE,
    card_header("Progress"),
    card_body(
      fillable = FALSE,
      uiOutput(paste0(id, "_bar")),
      div(style = "height: 130px; overflow-y: auto; font-family: monospace; font-size: 0.8em; margin-top: 0.75rem;",
          uiOutput(paste0(id, "_log")))
    )
  )
}

# Card for a results table. It's never squeezed by the cards above it: it is
# at least 500px tall and grows to fit the 10 rows on a page (rows with long
# citations wrap onto two lines). The page scrolls when the window is small.
table_card <- function(header, output) {
  card(fill = FALSE, full_screen = TRUE, header,
       card_body(fillable = FALSE, style = "min-height: 500px;", output))
}

search_tab <- nav_panel(
  "1. Find publications",
  layout_sidebar(
    sidebar = sidebar(
      width = 340,
      textInput("condition", "Disease or condition", "Non-Small Cell Lung Cancer OR NSCLC"),
      helpText("Uses ClinicalTrials.gov search syntax; OR and quotes work."),
      checkboxGroupInput("phases", "Study phase", PHASE_CHOICES, selected = c("PHASE2", "PHASE3")),
      helpText("A combined-phase trial (e.g. Phase 1/2) is kept if any of its phases is ticked."),
      selectizeInput("statuses", "Recruitment status", STATUS_CHOICES, selected = "COMPLETED", multiple = TRUE),
      accordion(
        open = FALSE,
        accordion_panel(
          "More filters",
          checkboxGroupInput("intervention_types", "Intervention type (any of)", INTERVENTION_CHOICES,
                             selected = c("DRUG", "BIOLOGICAL", "COMBINATION_PRODUCT")),
          checkboxGroupInput("purposes", "Primary purpose", PURPOSE_CHOICES, selected = "TREATMENT"),
          checkboxInput("require_enrollment", "Enrollment must be reported", TRUE),
          checkboxInput("check_access", "Check open access in Europe PMC (adds ~0.2 s per paper)", TRUE),
          numericInput("max_studies", "Stop if the search matches more than this many trials", 5000, min = 100, step = 500)
        )
      ),
      input_task_button("search", "Search", icon = icon("magnifying-glass"))
    ),
    fillable = FALSE,
    uiOutput("search_summary"),
    progress_card("search"),
    table_card(
      card_header(class = "d-flex justify-content-between align-items-center",
                  "Publications found", uiOutput("doi_download_ui", inline = TRUE)),
      DT::DTOutput("doi_table")
    )
  )
)

collect_tab <- nav_panel(
  "2. Collect data",
  layout_sidebar(
    sidebar = sidebar(
      width = 340,
      radioButtons("doi_source", "DOI list", c("From step 1" = "step1", "Upload a file" = "upload")),
      conditionalPanel("input.doi_source == 'upload'",
        fileInput("doi_file", NULL, accept = ".xlsx", placeholder = "DOI list (.xlsx)"),
        helpText("Needs a 'doi' column; 'nct_id', 'pmid', 'access_type' and 'citation' are used if present.")
      ),
      radioButtons("template_source", "Output template", c("Default template" = "default", "Upload a template" = "upload")),
      conditionalPanel("input.template_source == 'upload'",
        fileInput("template_file", NULL, accept = ".xlsx", placeholder = "Empty template (.xlsx)"),
        helpText("Each sheet's header row lists the variables to collect. A 'codebook' sheet is kept as is.")
      ),
      downloadLink("default_template_dl", "Download the default template"),
      radioButtons("codebook_source", "Codebook", c("Template's 'codebook' sheet" = "template", "Upload a codebook" = "upload")),
      conditionalPanel("input.codebook_source == 'upload'",
        fileInput("codebook_file", NULL, accept = c(".xlsx", ".csv", ".txt", ".md"), placeholder = "Codebook (.xlsx, .csv, .txt)")
      ),
      numericInput("batch_size", "Papers per message to the agent", 10, min = 1, max = 20, step = 1),
      helpText("Fewer round trips with more papers per message. If a message fails, its papers are retried one by one."),
      input_task_button("collect", "Run the agent", icon = icon("robot")),
      uiOutput("backend_note")
    ),
    fillable = FALSE,
    progress_card("collect"),
    table_card(
      card_header(class = "d-flex justify-content-between align-items-center",
                  "Collected data", uiOutput("results_download_ui", inline = TRUE)),
      uiOutput("results_tabs")
    )
  )
)

help_tab <- nav_panel(
  "Help",
  card(
    card_header("How it works"),
    markdown("
**1. Find publications.** The app searches ClinicalTrials.gov for interventional trials
that match your disease, phase and status, then keeps trials that pass all the filters.
For each trial it takes the results papers the trial record links to (sponsor-marked
*RESULT* references first, then *DERIVED* ones linked by the National Library of Medicine)
and looks up the DOI in PubMed. When several trials link to the same paper, only the
lowest NCT ID keeps it.

The Excel download has three sheets:
- `input_dois`: one row per paper, in the format the data-collection agent reads.
- `all_candidate_trials`: every trial that passed the filters, including those with no paper.
- `search_settings`: the inputs used, so the search can be repeated.

Review the DOI list before step 2. You can delete rows and upload the edited file there.

**2. Collect data.** The agent reads each paper and fills the template, one sheet per
template sheet (for the default template: `included_arms`, `excluded`, `failed_papers`).
Every value should be checked against the paper, starting with rows whose `notes`
begin with a flag such as `CHECK:`.
")
  )
)

ui <- page_navbar(
  title = "Trial data collection",
  theme = bs_theme(version = 5, preset = "flatly") |>
    # Smaller table text, and darker green for the tables' page bar (Previous / 1 2 3 / Next)
    bs_add_rules("
      .dataTables_wrapper { font-size: 0.85rem; }
      /* Summary boxes: start contents at the top so titles line up even when one box has a note */
      .summary-box .card-body { padding: 0 !important; }
      .summary-box .value-box-area {
        justify-content: flex-start !important; padding: 0.8rem 1rem 0.4rem !important; overflow: visible;
      }
      .summary-box .value-box-area > * { margin-bottom: 0.15rem; }
      .dataTables_wrapper .pagination .page-link {
        background-color: #0f7a61; border-color: #0f7a61; color: #fff;
      }
      .dataTables_wrapper .pagination .page-link:hover,
      .dataTables_wrapper .pagination .page-item.active .page-link {
        background-color: #08503f; border-color: #08503f; color: #fff;
      }
      .dataTables_wrapper .pagination .page-item.disabled .page-link {
        background-color: #5fa898; border-color: #5fa898; color: #e6f2ef;
      }
    "),
  search_tab, collect_tab, help_tab
)

## ---- Server -------------------------------------------------------------

server <- function(input, output, session) {

  # Show a progress bar and log from a background job's progress file.
  watch_progress <- function(id, path_rv, task) {
    output[[paste0(id, "_bar")]] <- renderUI({
      if (task$status() == "running") invalidateLater(1000)
      p <- read_progress(path_rv())
      pct <- round(100 * (if (is.na(p$fraction)) 0 else p$fraction))
      div(class = "progress", style = "height: 1.4rem;",
          div(class = "progress-bar", role = "progressbar", style = sprintf("width: %d%%;", pct), sprintf("%d%%", pct)))
    })
    output[[paste0(id, "_log")]] <- renderUI({
      if (task$status() == "running") invalidateLater(1000)
      log <- read_progress(path_rv())$log
      if (task$status() == "error") {
        msg <- tryCatch(task$result(), error = function(e) conditionMessage(e))
        log <- c(log, paste("ERROR:", msg))
      }
      if (length(log) == 0) return(span(class = "text-muted", "Not started."))
      HTML(paste(htmltools::htmlEscape(rev(log)), collapse = "<br>"))
    })
  }

  ## Step 1: search -------------------------------------------------------

  search_progress_path <- reactiveVal(NULL)
  search_params <- reactiveVal(NULL)
  search_time <- reactiveVal(NULL)

  search_task <- ExtendedTask$new(function(args, progress_path) {
    future_promise({
      load_app_functions(args$app_dir)
      do.call(search_trials, c(args$params, list(progress = progress_writer(progress_path))))
    }, seed = TRUE)
  }) |> bind_task_button("search")

  observeEvent(input$search, {
    validate_msg <- if (!nzchar(trimws(input$condition))) "Enter a disease or condition."
      else if (length(input$statuses) == 0) "Choose at least one recruitment status."
      else NULL
    if (!is.null(validate_msg)) {
      showNotification(validate_msg, type = "error")
      return()
    }
    params <- list(
      condition = trimws(input$condition),
      statuses = input$statuses,
      phases = input$phases,
      intervention_types = input$intervention_types,
      purposes = input$purposes,
      require_enrollment = input$require_enrollment,
      check_access = input$check_access,
      max_studies = input$max_studies
    )
    search_params(params)
    search_time(format(Sys.time(), "%Y-%m-%d %H:%M"))
    path <- tempfile("search_progress_", fileext = ".txt")
    search_progress_path(path)
    search_task$invoke(list(app_dir = APP_DIR, params = params), path)
  })

  watch_progress("search", search_progress_path, search_task)

  search_result <- reactive({
    req(search_task$status() == "success")
    search_task$result()
  })

  search_settings <- reactive({
    req(search_result())
    p <- search_params()
    data.frame(
      setting = c(names(p), "searched_on"),
      value = c(vapply(p, function(v) paste(v, collapse = ", "), character(1)), search_time())
    )
  })

  output$search_summary <- renderUI({
    r <- search_result()
    n <- r$counts
    # Short boxes: small icon beside the title instead of a large one above it
    box <- function(title, value, icon_name, ...) {
      value_box(span(style = "white-space: nowrap;", icon(icon_name), title), value, ...,
                fill = FALSE, height = "120px", class = "summary-box")
    }
    boxes <- list(
      box("Matching trials", n$matched, "flask"),
      box("Pass all filters", n$candidates, "filter"),
      box("Papers with a DOI", n$dois, "file-lines")
    )
    # Only shown when the Europe PMC access check was run
    if (isTRUE(n$access_checked)) {
      note <- sprintf("+ %d free to read", n$free_access)
      if (n$access_failed > 0) note <- paste0(note, sprintf(", %d not checked", n$access_failed))
      boxes[[length(boxes) + 1]] <- box("Open access", n$open_access, "lock-open",
                        p(class = "mb-0", style = "font-size: 0.75rem;", note))
    }
    do.call(layout_column_wrap, c(list(width = 1 / length(boxes), fill = FALSE), boxes))
  })

  output$doi_table <- DT::renderDT({
    d <- search_result()$dois
    d$doi <- sprintf('<a href="https://doi.org/%s" target="_blank">%s</a>', d$doi, d$doi)
    DT::datatable(d, escape = setdiff(names(d), "doi"), rownames = FALSE,
                  options = list(pageLength = 10, scrollX = TRUE,
                                 columnDefs = list(list(targets = 4, render = DT::JS(
                                   "function(d,t){return t==='display'&&d&&d.length>80?d.substr(0,80)+'…':d;}")))))
  })

  output$doi_download_ui <- renderUI({
    req(search_result())
    downloadButton("doi_download", "Download DOIs (.xlsx)", class = "btn-sm btn-primary")
  })

  output$doi_download <- downloadHandler(
    filename = function() sprintf("dois_%s.xlsx", format(Sys.Date())),
    content = function(file) write_doi_workbook(search_result(), search_settings(), file)
  )

  ## Step 2: collect ------------------------------------------------------

  output$default_template_dl <- downloadHandler(
    filename = "output_template.xlsx",
    content = function(file) file.copy(DEFAULT_TEMPLATE, file)
  )

  output$backend_note <- renderUI({
    backend <- Sys.getenv("AGENT_BACKEND", "mock")
    if (backend == "mock") {
      div(class = "alert alert-warning mt-2 small",
          strong("Test mode: "), "a placeholder agent fills the template with made-up rows.")
    } else if (backend == "copilot") {
      div(class = "text-muted small mt-2",
          "Agent: Copilot Studio, running under your Microsoft account.")
    } else {
      div(class = "text-muted small mt-2", sprintf("Agent backend: %s", backend))
    }
  })

  collect_progress_path <- reactiveVal(NULL)
  collect_template_path <- reactiveVal(NULL)

  collect_task <- ExtendedTask$new(function(args, progress_path) {
    future_promise({
      load_app_functions(args$app_dir)
      run_agent(args$dois, args$template_path, args$codebook_path, args$instructions,
                progress = progress_writer(progress_path), token = args$token,
                batch_size = args$batch_size)
    }, seed = TRUE)
  }) |> bind_task_button("collect")

  observeEvent(input$collect, {
    inputs <- tryCatch({
      dois <- if (input$doi_source == "step1") {
        if (search_task$status() != "success") stop("Run a search in step 1 first, or upload a DOI file.")
        search_result()$dois
      } else {
        if (is.null(input$doi_file)) stop("Upload a DOI file.")
        read_doi_list(input$doi_file$datapath)
      }
      if (nrow(dois) == 0) stop("The DOI list is empty.")

      template_path <- if (input$template_source == "default") DEFAULT_TEMPLATE else {
        if (is.null(input$template_file)) stop("Upload a template.")
        input$template_file$datapath
      }
      read_template(template_path)  # fail early on a bad template

      codebook_path <- if (input$codebook_source == "upload") {
        if (is.null(input$codebook_file)) stop("Upload a codebook.")
        input$codebook_file$datapath
      } else NULL
      read_codebook(codebook_path, template_path)  # fail early if there is no codebook

      # Uploaded files are deleted when the session ends; copy them so the
      # background job can still read them.
      keep <- function(p) if (is.null(p)) NULL else {
        dest <- tempfile(fileext = paste0(".", tools::file_ext(p))); file.copy(p, dest); dest
      }
      # The Copilot Studio agent runs as the signed-in user; get their token
      # here, where the Shiny session is available.
      token <- if (Sys.getenv("AGENT_BACKEND", "mock") == "copilot") copilot_token(session, APP_DIR) else NULL

      batch_size <- if (is.na(input$batch_size)) 10 else min(max(round(input$batch_size), 1), 20)

      list(dois = dois, template_path = keep(template_path), codebook_path = keep(codebook_path),
           token = token, batch_size = batch_size)
    }, error = function(e) {
      showNotification(conditionMessage(e), type = "error", duration = 8)
      NULL
    })
    req(inputs)

    path <- tempfile("collect_progress_", fileext = ".txt")
    collect_progress_path(path)
    collect_template_path(inputs$template_path)
    collect_task$invoke(c(inputs, list(app_dir = APP_DIR, instructions = read_instructions())), path)
  })

  watch_progress("collect", collect_progress_path, collect_task)

  collect_result <- reactive({
    req(collect_task$status() == "success")
    collect_task$result()
  })

  output$results_tabs <- renderUI({
    res <- collect_result()
    tabs <- lapply(names(res), function(s) {
      nav_panel(sprintf("%s (%d)", s, nrow(res[[s]])), DT::DTOutput(paste0("res_", s)))
    })
    do.call(navset_card_underline, tabs)
  })

  observe({
    res <- collect_result()
    for (s in names(res)) local({
      sheet <- s
      output[[paste0("res_", sheet)]] <- DT::renderDT(
        DT::datatable(res[[sheet]], rownames = FALSE, options = list(pageLength = 10, scrollX = TRUE))
      )
    })
  })

  output$results_download_ui <- renderUI({
    req(collect_result())
    tagList(
      downloadButton("results_download", "Download data (.xlsx)", class = "btn-sm btn-primary"),
      downloadButton("log_download", "Progress log", class = "btn-sm btn-outline-secondary")
    )
  })

  output$results_download <- downloadHandler(
    filename = function() sprintf("collected_data_%s.xlsx", format(Sys.Date())),
    content = function(file) write_results_workbook(collect_result(), collect_template_path(), file)
  )

  output$log_download <- downloadHandler(
    filename = function() sprintf("progress_log_%s.txt", format(Sys.Date())),
    content = function(file) writeLines(read_progress(collect_progress_path())$log, file)
  )
}

shinyApp(ui, server)
