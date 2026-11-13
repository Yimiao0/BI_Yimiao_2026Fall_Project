# Trial publication finder and data collection app.
#
# Tab 1: search ClinicalTrials.gov, link trials to their results papers, and
#        download the paper list as Excel.
# Tab 2: send the paper list, an output template and a codebook to the
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
DEFAULT_INSTRUCTIONS <- file.path(APP_DIR, "defaults", c("collection_rules.txt", "exclusion_rules.txt"))

# Run inside the background process: load the app's functions there too.
load_app_functions <- function(app_dir) {
  options(app_dir = app_dir)
  for (f in list.files(file.path(app_dir, "R"), pattern = "\\.R$", full.names = TRUE)) source(f, local = FALSE)
}

# The rules sent to the agent with every batch: the default NSCLC rule files,
# or one uploaded .txt/.md file that replaces them.
read_instructions <- function(path = NULL) {
  files <- if (is.null(path)) DEFAULT_INSTRUCTIONS[file.exists(DEFAULT_INSTRUCTIONS)] else path
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
table_card <- function(header, ...) {
  card(fill = FALSE, full_screen = TRUE, header,
       card_body(fillable = FALSE, style = "min-height: 500px;", ...))
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
          numericInput("max_studies", "Warn if the search matches more than this many trials", 5000, min = 100, step = 500)
        )
      ),
      input_task_button("search", "Search", icon = icon("magnifying-glass"))
    ),
    fillable = FALSE,
    uiOutput("search_summary"),
    progress_card("search"),
    table_card(
      card_header(class = "d-flex justify-content-between align-items-center",
                  "Publications found", uiOutput("paper_download_ui", inline = TRUE)),
      # Gap between the two options set inline on the first label
      radioButtons("access_keep", NULL, inline = TRUE, selected = "open",
                   choiceNames = list(span(style = "margin-right: 3rem;", names(ACCESS_KEEP_CHOICES)[1]),
                                      names(ACCESS_KEEP_CHOICES)[2]),
                   choiceValues = unname(ACCESS_KEEP_CHOICES)),
      DT::DTOutput("paper_table")
    )
  )
)

collect_tab <- nav_panel(
  "2. Collect data",
  layout_sidebar(
    sidebar = sidebar(
      width = 340,
      radioButtons("paper_source", "Paper list", c("From step 1" = "step1", "Upload a file" = "upload")),
      conditionalPanel("input.paper_source == 'upload'",
        fileInput("paper_file", NULL, accept = ".xlsx", placeholder = "Paper list (.xlsx)"),
        helpText("Needs a 'pmid', 'doi' or 'pmcid' column; 'nct_id', 'access_type' and 'citation' are used if present.")),
      helpText("Only open-access papers are sent to the agent."),
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
      radioButtons("rules_source", "Rules", c("Default rules (NSCLC)" = "default", "Upload rules" = "upload")),
      conditionalPanel("input.rules_source == 'upload'",
        fileInput("rules_file", NULL, accept = c(".txt", ".md"), placeholder = "Rules (.txt, .md)"),
        helpText("The collection and exclusion rules for your disease and template. They replace the default rules.")
      ),
      downloadLink("default_rules_dl", "Download the default rules", class = "d-block mb-3"),
      input_task_button("test_agent", "Test the agent on 10 papers", icon = icon("vial"),
                        class = "btn-outline-primary mb-2"),
      input_task_button("collect", "Run the agent", icon = icon("robot")),
      uiOutput("stop_ui"),
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
Each trial is linked to the first results paper in its record that has a PubMed ID
(sponsor-marked *RESULT* references first, then *DERIVED* ones linked by the National Library
of Medicine). The app then looks each paper up in Europe PMC for its DOI, its PubMed Central
ID (PMCID) and whether it's open access. When several trials link to the same paper, only the
lowest NCT ID keeps it.

**The filter above the publications table:** *Open access* keeps only papers whose full text Europe PMC
provides openly, with a PubMed Central ID, so the AI agent can read them. *All linked papers* also keeps papers that
aren't open access (free only on the journal site, or paywalled).

The Excel download has four sheets:
- `input_papers`: the listed papers, in the format the data-collection agent reads.
- `all_linked_papers`: every linked paper, whatever its access.
- `all_candidate_trials`: every trial that passed the filters, including those with no paper.
- `search_settings`: the inputs used, so the search can be repeated.

Review the paper list before step 2. You can delete rows and upload the edited file there.

**2. Collect data.** Only open-access papers are sent to the agent, whichever paper list
you use; the others are skipped and counted in the progress log. *Stop* ends a run after the
batch of 10 papers in progress; the papers done so far are kept and can be downloaded. The agent reads each paper and fills the template, one sheet per
template sheet (for the default template: `included_arms`, `excluded`, `failed_papers`).
The agent also gets the collection and exclusion rules with every batch. The default
rules are for NSCLC; for another disease or template, download them, adapt them and upload
your own under *Rules*.
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
                fill = FALSE, height = "145px", class = "summary-box")
    }
    boxes <- list(
      box("Trials found", n$candidates, "flask"),
      box("Linked papers", n$papers, "file-lines")
    )
    note <- if (n$access_failed > 0) {
      p(class = "mb-0", style = "font-size: 0.75rem;", sprintf("%d papers couldn't be checked", n$access_failed))
    }
    boxes[[length(boxes) + 1]] <- box("Open access", n$open_access, "lock-open", note)
    do.call(layout_column_wrap, c(list(width = 1 / length(boxes), fill = FALSE), boxes))
  })

  # Papers kept for the list, download and step 2, by access type
  kept_papers <- reactive({
    keep_by_access(search_result()$papers, input$access_keep)
  })

  output$paper_table <- DT::renderDT({
    d <- kept_papers()
    d$doi <- ifelse(is.na(d$doi), "", sprintf('<a href="https://doi.org/%s" target="_blank">%s</a>', d$doi, d$doi))
    # PubMed Central page: the full text the agent reads
    d$pmcid <- ifelse(is.na(d$pmcid), "", sprintf('<a href="https://pmc.ncbi.nlm.nih.gov/articles/%s/" target="_blank">%s</a>', d$pmcid, d$pmcid))
    DT::datatable(d, escape = setdiff(names(d), c("doi", "pmcid")), rownames = FALSE,
                  options = list(pageLength = 10, scrollX = TRUE,
                                 columnDefs = list(list(targets = which(names(d) == "citation") - 1, render = DT::JS(
                                   "function(d,t){return t==='display'&&d&&d.length>80?d.substr(0,80)+'…':d;}")))))
  })

  output$paper_download_ui <- renderUI({
    req(search_result())
    downloadButton("paper_download", "Download papers (.xlsx)", class = "btn-sm btn-primary")
  })

  output$paper_download <- downloadHandler(
    filename = function() {
      which <- if (identical(input$access_keep, "open")) "open_access" else "all_papers"
      sprintf("papers_%s_%s.xlsx", which, format(Sys.Date()))
    },
    content = function(file) write_paper_workbook(search_result(), search_settings(), file, kept_papers())
  )

  ## Step 2: collect ------------------------------------------------------

  output$default_template_dl <- downloadHandler(
    filename = "output_template.xlsx",
    content = function(file) file.copy(DEFAULT_TEMPLATE, file)
  )
  output$default_rules_dl <- downloadHandler(
    filename = "default_rules_NSCLC.md",
    content = function(file) writeLines(read_instructions(), file)
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
    stop_file <- stop_file_for(progress_path)
    future_promise({
      load_app_functions(args$app_dir)
      run_agent(args$papers, args$template_path, args$codebook_path, args$instructions,
                progress = progress_writer(progress_path), token = args$token,
                max_papers = args$max_papers, stop_file = stop_file)
    }, seed = TRUE)
  }) |> bind_task_button("collect") |> bind_task_button("test_agent")

  # Start a run: all papers ("Run the agent") or the first 10 ("Test the agent")
  start_collect <- function(max_papers) {
    inputs <- tryCatch({
      papers <- if (input$paper_source == "step1") {
        if (search_task$status() != "success") stop("Run a search in step 1 first, or upload a paper list.")
        kept_papers()
      } else {
        if (is.null(input$paper_file)) stop("Upload a paper list.")
        read_paper_list(input$paper_file$datapath)
      }
      if (nrow(papers) == 0) stop("The paper list is empty.")

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

      rules <- if (input$rules_source == "upload") {
        if (is.null(input$rules_file)) stop("Upload a rules file.")
        read_instructions(input$rules_file$datapath)
      } else read_instructions()
      if (!nzchar(trimws(rules))) stop("The rules file is empty.")

      # Uploaded files are deleted when the session ends; copy them so the
      # background job can still read them.
      keep <- function(p) if (is.null(p)) NULL else {
        dest <- tempfile(fileext = paste0(".", tools::file_ext(p))); file.copy(p, dest); dest
      }
      # The Copilot Studio agent runs as the signed-in user; get their token
      # here, where the Shiny session is available.
      token <- if (Sys.getenv("AGENT_BACKEND", "mock") == "copilot") copilot_token(session, APP_DIR) else NULL

      list(papers = papers, template_path = keep(template_path), codebook_path = keep(codebook_path),
           token = token, max_papers = max_papers, instructions = rules)
    }, error = function(e) {
      showNotification(conditionMessage(e), type = "error", duration = 8)
      NULL
    })
    req(inputs)

    path <- tempfile("collect_progress_", fileext = ".txt")
    collect_progress_path(path)
    collect_template_path(inputs$template_path)
    collect_task$invoke(c(inputs, list(app_dir = APP_DIR)), path)
  }
  observeEvent(input$collect, start_collect(Inf))
  observeEvent(input$test_agent, start_collect(10))

  watch_progress("collect", collect_progress_path, collect_task)

  # Stop: the background run checks for this file before each batch of papers
  stop_file_for <- function(progress_path) paste0(progress_path, ".stop")
  request_stop <- function(path) {
    if (!is.null(path) && !file.exists(stop_file_for(path))) file.create(stop_file_for(path))
  }
  output$stop_ui <- renderUI({
    if (collect_task$status() != "running") return(NULL)
    actionButton("stop_agent", "Stop", icon = icon("stop"), class = "btn-outline-danger w-100 mt-2")
  })
  observeEvent(input$stop_agent, {
    path <- collect_progress_path()
    if (is.null(path) || file.exists(stop_file_for(path))) return()
    request_stop(path)
    # Name the batch in progress, from the run's last "Sending papers a-b of n" line
    p <- read_progress(path)
    sending <- regmatches(p$log, regexpr("papers [0-9]+-[0-9]+(?= of)", p$log, perl = TRUE))
    msg <- if (length(sending) > 0) {
      sprintf("Stopping after the current batch (%s)...", sending[length(sending)])
    } else "Stopping before the first batch is sent..."
    progress_writer(path)(p$fraction, msg)
  })
  # Closing or reloading the page stops the run too: nobody would see its results
  session$onSessionEnded(function() request_stop(isolate(collect_progress_path())))

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
