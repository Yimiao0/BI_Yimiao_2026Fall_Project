# Step 2 of the app: send each paper to the data-collection agent and gather
# its rows into the output template.
#
# The app only talks to the agent through agent_process_batch(). Which agent
# answers is set by the AGENT_BACKEND environment variable:
#   "mock" (default) - placeholder answers, no external service; for testing the app
#   "http"           - a hosted agent reached over HTTP (AGENT_URL, AGENT_API_KEY);
#                      see "HTTP contract" below
#   "copilot"        - the Copilot Studio agent, through Microsoft's Python SDK
#                      (python/copilot_agent.py); see app/README.md for setup
# To plug in a different agent (e.g. Copilot Studio via Direct Line), write
# another agent_<name>() function with the same arguments and return value,
# and add it to agent_process_batch().

CODEBOOK_SHEET <- "codebook"

#' Read the template: one entry per data sheet, holding its column names.
read_template <- function(path) {
  sheets <- setdiff(readxl::excel_sheets(path), CODEBOOK_SHEET)
  if (length(sheets) == 0) stop("The template has no data sheets.")
  setNames(lapply(sheets, function(s) names(readxl::read_excel(path, sheet = s, n_max = 0))), sheets)
}

#' Read the codebook from its own file (.xlsx, .csv, .txt, .md) or, when none
#' is given, from the template's "codebook" sheet. Returns plain text for the agent.
read_codebook <- function(codebook_path = NULL, template_path = NULL) {
  as_text <- function(df) paste(utils::capture.output(utils::write.csv(df, row.names = FALSE)), collapse = "\n")
  if (!is.null(codebook_path)) {
    ext <- tolower(tools::file_ext(codebook_path))
    if (ext %in% c("xlsx", "xls")) return(as_text(readxl::read_excel(codebook_path)))
    if (ext == "csv") return(as_text(utils::read.csv(codebook_path, check.names = FALSE)))
    return(paste(readLines(codebook_path, warn = FALSE), collapse = "\n"))
  }
  if (!is.null(template_path) && CODEBOOK_SHEET %in% readxl::excel_sheets(template_path)) {
    return(as_text(readxl::read_excel(template_path, sheet = CODEBOOK_SHEET)))
  }
  stop("No codebook: upload one, or use a template with a 'codebook' sheet.")
}

#' Read a paper list: the app's own download, or any sheet with a pmid, doi
#' or pmcid column. Rows with none of the three are dropped.
read_paper_list <- function(path) {
  sheets <- readxl::excel_sheets(path)
  sheet <- intersect(c("input_papers", "input_dois"), sheets)[1]
  if (is.na(sheet)) sheet <- sheets[1]
  df <- as.data.frame(readxl::read_excel(path, sheet = sheet, col_types = "text"))
  if (!any(c("pmid", "doi", "pmcid") %in% names(df))) {
    stop("The paper list needs a column named 'pmid', 'doi' or 'pmcid'.")
  }
  for (col in PAPER_COLUMNS) if (!col %in% names(df)) df[[col]] <- NA_character_
  has_id <- function(x) !is.na(x) & nzchar(trimws(x))
  df <- df[has_id(df$pmid) | has_id(df$doi) | has_id(df$pmcid), ]
  if (nrow(df) == 0) stop("The paper list has no PubMed IDs, DOIs or PMCIDs.")
  df
}

## ---- Backends -----------------------------------------------------------

#' Placeholder agent: returns made-up rows in the template's shape so the
#' whole app can be tested. Papers that aren.t open access go to failed_papers, every 7th
#' paper is excluded, the rest get two arms.
agent_mock <- function(paper, columns, codebook, instructions, paper_index) {
  Sys.sleep(stats::runif(1, 0.5, 1.5))
  out <- list()
  if (!is.na(paper$access_type) && paper$access_type != "open_access" && "failed_papers" %in% names(columns)) {
    out$failed_papers <- data.frame(nct_id = paper$nct_id, doi = paper$doi,
                                    reason = "MOCK: no free full text")
  } else if (paper_index %% 7 == 0 && "excluded" %in% names(columns)) {
    out$excluded <- data.frame(nct_id = paper$nct_id, doi = paper$doi, exclusion_level = "paper",
                               exclusion_code = "MOCK", exclusion_evidence = "MOCK: placeholder exclusion")
  } else {
    main <- names(columns)[1]
    out[[main]] <- data.frame(nct_id = paper$nct_id, doi = paper$doi,
                              arm_label = c("Arm A (mock)", "Arm B (mock)"),
                              notes = "MOCK: placeholder values, not read from the paper")
  }
  out
}

#' Hosted agent over HTTP.
#'
#' HTTP contract (what the real agent must accept and return):
#'   POST AGENT_URL, header "Authorization: Bearer <AGENT_API_KEY>", JSON body:
#'     { "paper": {nct_id, pmid, pmcid, doi, access_type, citation},
#'       "columns": {"<sheet>": ["col1", ...], ...},
#'       "codebook": "<text>", "instructions": "<text>" }
#'   Response JSON: {"<sheet>": [ {col: value, ...}, ... ], ...}
#'   e.g. {"included_arms": [...], "excluded": [...], "failed_papers": []}
agent_http <- function(paper, columns, codebook, instructions, paper_index) {
  url <- Sys.getenv("AGENT_URL")
  if (!nzchar(url)) stop("AGENT_BACKEND is 'http' but AGENT_URL is not set.")
  resp <- httr2::request(url) |>
    httr2::req_auth_bearer_token(Sys.getenv("AGENT_API_KEY")) |>
    httr2::req_body_json(list(
      paper = as.list(paper),
      columns = lapply(columns, I),
      codebook = codebook,
      instructions = instructions
    ), auto_unbox = TRUE, na = "null") |>
    httr2::req_retry(max_tries = 3) |>
    httr2::req_timeout(900) |>
    httr2::req_perform()
  body <- httr2::resp_body_json(resp, simplifyVector = TRUE)
  lapply(body, as.data.frame)
}

## ---- Copilot Studio (through Microsoft's Python SDK) ---------------------

#' Load python/copilot_agent.py once per R process. Uses the Python set by
#' RETICULATE_PYTHON, else app/.venv when it exists (local testing).
copilot_py <- local({
  mod <- NULL
  function(app_dir = getOption("app_dir", ".")) {
    if (is.null(mod)) {
      venv <- file.path(app_dir, ".venv")
      if (!nzchar(Sys.getenv("RETICULATE_PYTHON")) && dir.exists(venv)) reticulate::use_virtualenv(venv, required = TRUE)
      mod <<- reticulate::import_from_path("copilot_agent", path = file.path(app_dir, "python"))
    }
    mod
  }
})

#' The message sent to the agent for one paper. The agent's own instructions
#' (set in Copilot Studio) cover how to read papers; this message says which
#' paper and the exact reply format the app can read.
#' `papers` is a data frame of one or more papers (rows of the paper list).
copilot_message <- function(papers, columns, codebook, rules = "") {
  sheets <- paste(sprintf('- "%s": %s', names(columns),
                          vapply(columns, paste, character(1), collapse = ", ")), collapse = "\n")
  paper_list <- paste(sprintf(
    "%d. nct_id: %s; pmid: %s; pmcid: %s; doi: %s; access_type: %s; citation: %s",
    seq_len(nrow(papers)), papers$nct_id, papers$pmid, papers$pmcid, papers$doi, papers$access_type, papers$citation
  ), collapse = "\n")
  n <- nrow(papers)
  paste0(
    if (n == 1) "Process this one paper" else sprintf("Process these %d papers, each on its own,", n),
    " following your instructions.\n\n",
    "Papers:\n", paper_list, "\n\n",
    "Reply with one JSON object only, no other text. Its keys are sheet names, ",
    "each holding a list of rows; each row is an object keyed by column name. ",
    "Every row must include the paper's nct_id, pmid and doi as listed (null if empty), even if a sheet has no column for them. Every paper must appear in at least one sheet ",
    "(as data rows, an exclusion, or a failure). ",
    "Use null for values not reported. Leave out sheets with no rows.\n",
    "Sheets and columns:\n", sheets, "\n\n",
    "Codebook:\n", codebook,
    if (nzchar(rules)) paste0("\n\nRules:\n", rules)
  )
}

#' Pull the JSON object out of the agent's reply (it may add code fences or a
#' sentence around it) and turn it into one data frame per sheet.
parse_agent_json <- function(reply) {
  start <- regexpr("{", reply, fixed = TRUE)
  ends <- gregexpr("}", reply, fixed = TRUE)[[1]]
  if (start < 0 || ends[1] < 0) stop("The agent's reply has no JSON: ", substr(reply, 1, 300))
  json <- substr(reply, start, max(ends))
  body <- jsonlite::fromJSON(json, simplifyVector = TRUE)
  lapply(body, function(rows) if (length(rows) == 0) data.frame() else as.data.frame(rows))
}

#' Send a batch of papers (one or more) to the Copilot Studio agent in one
#' message. Time limit: COPILOT_TIMEOUT_SECONDS (default 300) per paper, at
#' least 15 minutes per message.
agent_copilot <- function(papers, columns, codebook, instructions = "", token = NULL) {
  url <- Sys.getenv("COPILOT_CONNECTION_STRING")
  if (!nzchar(url)) stop("AGENT_BACKEND is 'copilot' but COPILOT_CONNECTION_STRING is not set.")
  if (is.null(token) || !nzchar(token)) stop("No Microsoft sign-in token for the Copilot Studio agent.")
  timeout <- max(900, as.numeric(Sys.getenv("COPILOT_TIMEOUT_SECONDS", "300")) * nrow(papers))
  reply <- copilot_py()$ask_agent(url, token, copilot_message(papers, columns, codebook, instructions), timeout)
  parse_agent_json(reply)
}

#' Get the signed-in user's token for Copilot Studio. Runs in the app's main
#' process (it needs the Shiny session), before the background job starts.
#'   On Posit Connect: from Connect's OAuth integration for the viewer.
#'   On your computer: COPILOT_TOKEN if set, else browser sign-in with
#'   COPILOT_TENANT_ID and COPILOT_CLIENT_ID.
copilot_token <- function(session, app_dir) {
  session_token <- session$request$HTTP_POSIT_CONNECT_USER_SESSION_TOKEN
  if (!is.null(session_token) && nzchar(session_token)) {
    creds <- connectapi::get_oauth_credentials(connectapi::connect(), session_token)
    return(creds$access_token)
  }
  if (nzchar(Sys.getenv("COPILOT_TOKEN"))) return(Sys.getenv("COPILOT_TOKEN"))
  tenant <- Sys.getenv("COPILOT_TENANT_ID"); client <- Sys.getenv("COPILOT_CLIENT_ID")
  if (!nzchar(tenant) || !nzchar(client)) {
    stop("To sign in locally, set COPILOT_TENANT_ID and COPILOT_CLIENT_ID (or COPILOT_TOKEN).")
  }
  copilot_py(app_dir)$get_token_local(tenant, client, Sys.getenv("COPILOT_CONNECTION_STRING"),
                                      file.path(app_dir, ".token_cache.json"))
}

#' The one function the app calls per batch of papers (a data frame of one or
#' more rows of the paper list). Returns a named list of data frames, one per
#' template sheet; sheets with no rows can be left out. Every row should carry
#' the nct_id, pmid and doi of the paper it belongs to.
#'
#' The Copilot Studio agent gets the whole batch in one message. The mock and
#' http agents take one paper per call, so they are called once per paper.
agent_process_batch <- function(papers, columns, codebook, instructions, first_index = 1, token = NULL) {
  backend <- Sys.getenv("AGENT_BACKEND", "mock")
  if (backend == "copilot") return(agent_copilot(papers, columns, codebook, instructions, token))

  one <- switch(backend, mock = agent_mock, http = agent_http,
                stop(sprintf("Unknown AGENT_BACKEND '%s'.", backend)))
  outs <- lapply(seq_len(nrow(papers)), function(k) {
    paper <- as.list(papers[k, ])
    tag_rows(one(paper, columns, codebook, instructions, first_index + k - 1), paper)
  })
  combine_outputs(outs)
}

#' Add the paper's IDs (nct_id, pmid, doi) to rows that lack them (only safe
#' when the output is known to be for this one paper).
tag_rows <- function(out, paper) {
  lapply(out, function(df) {
    if (NROW(df) == 0) return(df)
    for (id in c("nct_id", "pmid", "doi")) {
      if (!id %in% names(df)) df[[id]] <- paper[[id]]
      else df[[id]] <- ifelse(is.na(df[[id]]), paper[[id]], df[[id]])
    }
    df
  })
}

#' Which papers appear in some sheet of the output. Matched by PubMed ID or
#' DOI; by NCT ID only for a paper with neither.
papers_in_output <- function(papers, out) {
  ids <- function(col) {
    v <- unlist(lapply(out, function(df) if (col %in% names(df)) as.character(df[[col]])))
    tolower(trimws(v[!is.na(v)]))
  }
  key <- function(x) tolower(trimws(as.character(x)))
  has <- function(x) !is.na(x) & nzchar(trimws(x))
  by_pmid <- has(papers$pmid) & key(papers$pmid) %in% ids("pmid")
  by_doi <- has(papers$doi) & key(papers$doi) %in% ids("doi")
  by_nct <- !has(papers$pmid) & !has(papers$doi) & key(papers$nct_id) %in% ids("nct_id")
  by_pmid | by_doi | by_nct
}

#' Stack several outputs (named lists of data frames) sheet by sheet.
combine_outputs <- function(outs) {
  sheets <- unique(unlist(lapply(outs, names)))
  setNames(lapply(sheets, function(s) {
    dfs <- Filter(function(d) NROW(d) > 0, lapply(outs, `[[`, s))
    dplyr::bind_rows(lapply(dfs, function(d) dplyr::mutate(d, dplyr::across(dplyr::everything(), as.character))))
  }), sheets)
}

## ---- Run over all papers ------------------------------------------------

#' Match a data frame to the template's columns: add missing ones as NA, put
#' them in template order, and drop columns the template doesn't have.
conform <- function(df, cols) {
  df <- as.data.frame(df, stringsAsFactors = FALSE)
  for (c in setdiff(cols, names(df))) df[[c]] <- rep(NA, nrow(df))
  df[, cols, drop = FALSE]
}

#' A failed_papers row for each paper, with the reason.
failure_rows <- function(papers, reason) {
  list(failed_papers = data.frame(nct_id = papers$nct_id, pmid = papers$pmid, doi = papers$doi, reason = reason))
}

#' Process one batch. If the whole batch fails (e.g. the agent's reply can't
#' be read), retry its papers one by one so one bad paper doesn't lose the
#' rest. Papers the agent skipped are logged in failed_papers.
process_batch_safely <- function(papers, columns, codebook, instructions, first_index, token, progress) {
  out <- tryCatch(
    agent_process_batch(papers, columns, codebook, instructions, first_index, token),
    error = function(e) e
  )
  if (inherits(out, "error")) {
    if (nrow(papers) == 1) return(failure_rows(papers, paste("Agent error:", conditionMessage(out))))
    progress(NA, sprintf("Batch failed (%s); retrying its %d papers one by one",
                         substr(conditionMessage(out), 1, 120), nrow(papers)))
    return(combine_outputs(lapply(seq_len(nrow(papers)), function(k) {
      process_batch_safely(papers[k, , drop = FALSE], columns, codebook, instructions,
                           first_index + k - 1, token, progress)
    })))
  }

  # A one-paper batch: rows without IDs belong to that paper.
  if (nrow(papers) == 1) out <- tag_rows(out, as.list(papers[1, ]))

  # Papers that appear in no sheet at all
  missing <- papers[!papers_in_output(papers, out), , drop = FALSE]
  if (nrow(missing) > 0) out <- combine_outputs(list(out, failure_rows(missing, "The agent returned nothing for this paper")))
  out
}

#' Keep only open-access papers with a PMCID, the ones the agent can read.
#' Papers with no access type (e.g. from an uploaded file) are checked in
#' Europe PMC first.
open_access_only <- function(papers, progress = function(...) NULL) {
  unknown <- which(is.na(papers$access_type) | !nzchar(papers$access_type))
  if (length(unknown) > 0) {
    progress(0, sprintf("Checking open access in Europe PMC for %d papers", length(unknown)))
    access <- classify_access(papers[unknown, , drop = FALSE])
    papers$access_type[unknown] <- access$access_type
    papers$pmcid[unknown] <- ifelse(is.na(papers$pmcid[unknown]), access$pmcid, papers$pmcid[unknown])
    papers$doi[unknown] <- ifelse(is.na(papers$doi[unknown]), access$doi, papers$doi[unknown])
  }
  keep <- papers$access_type %in% "open_access" & !is.na(papers$pmcid) & nzchar(papers$pmcid)
  if (!any(keep)) stop("None of the papers is open access with a PMCID, so the agent can't read them.")
  if (any(!keep)) {
    progress(0, sprintf("Skipping %d papers that aren't open access or have no PMCID; sending %d to the agent",
                        sum(!keep), sum(keep)))
  }
  papers[keep, , drop = FALSE]
}

#' Process every paper, `batch_size` papers per message to the agent. A paper
#' that can't be processed is logged in failed_papers (when the template has
#' that sheet) and the run continues. If `stop_file` appears, the run stops
#' before the next batch and returns what's done so far.
run_agent <- function(papers, template_path, codebook_path = NULL, instructions = "",
                      progress = function(...) NULL, token = NULL, max_papers = Inf,
                      batch_size = 10, stop_file = NULL) {
  columns <- read_template(template_path)
  codebook <- read_codebook(codebook_path, template_path)
  papers <- open_access_only(papers[, PAPER_COLUMNS], progress)

  if (nrow(papers) > max_papers) {
    papers <- papers[seq_len(max_papers), , drop = FALSE]
    progress(0, sprintf("Test run: only the first %d open-access papers", max_papers))
  }
  n <- nrow(papers)
  batch_size <- max(1L, as.integer(batch_size))
  batches <- split(seq_len(n), ceiling(seq_len(n) / batch_size))
  last_fraction <- 0
  report <- function(fraction, message) {
    if (!is.na(fraction)) last_fraction <<- fraction
    progress(last_fraction, message)
  }
  report(0, sprintf("Starting: %d papers in %d messages of up to %d papers, agent backend '%s'",
                    n, length(batches), batch_size, Sys.getenv("AGENT_BACKEND", "mock")))

  outs <- vector("list", length(batches))
  for (b in seq_along(batches)) {
    idx <- batches[[b]]
    # The Stop button (or closing the page) writes stop_file; stop between batches
    if (!is.null(stop_file) && file.exists(stop_file)) {
      done <- idx[1] - 1
      report(NA, sprintf("Stopped by user: %d of %d papers done; %d not sent to data collection AI agent", done, n, n - done))
      break
    }
    report(NA, sprintf("Sending papers %d-%d of %d to the agent", idx[1], max(idx), n))
    outs[[b]] <- process_batch_safely(papers[idx, , drop = FALSE], columns, codebook, instructions,
                                      idx[1], token, report)
    report(max(idx) / n, sprintf("Papers %d-%d of %d done", idx[1], max(idx), n))
  }
  results <- combine_outputs(outs)
  # Batches can't number rows across each other, so number arm_id here
  if (NROW(results$included_arms) > 0 && "arm_id" %in% names(results$included_arms)) {
    results$included_arms$arm_id <- as.character(seq_len(nrow(results$included_arms)))
  }

  sheets <- lapply(names(columns), function(s) {
    rows <- results[[s]] %||% data.frame()
    if (nrow(rows) == 0) rows <- data.frame(matrix(nrow = 0, ncol = 0))
    df <- conform(rows, columns[[s]])
    if ("arm_id" %in% names(df) && nrow(df) > 0 && all(is.na(df$arm_id))) df$arm_id <- seq_len(nrow(df))
    # Store numbers as numbers in Excel, not text
    utils::type.convert(df, as.is = TRUE)
  })
  setNames(sheets, names(columns))
}

#' Write the results into a copy of the template, keeping its codebook sheet
#' and formatting.
write_results_workbook <- function(results, template_path, path) {
  wb <- openxlsx::loadWorkbook(template_path)
  for (s in names(results)) {
    openxlsx::writeData(wb, s, results[[s]], startRow = 1, colNames = TRUE)
  }
  openxlsx::saveWorkbook(wb, path, overwrite = TRUE)
}
