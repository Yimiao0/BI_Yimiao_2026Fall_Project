# Step 1 (nsclc_data_collection_workflow.md): Pull candidate trials via the
# ClinicalTrials.gov v2 REST API.
#
# Query: query.cond = "Non-Small Cell Lung Cancer", filter.overallStatus = COMPLETED
# Output: full candidate pool of completed NSCLC trials, before any manual
# screening (screening happens in later steps).

required_pkgs <- c("httr", "jsonlite", "dplyr", "purrr", "tibble")
missing_pkgs <- setdiff(required_pkgs, rownames(installed.packages()))
if (length(missing_pkgs) > 0) install.packages(missing_pkgs)

library(httr)
library(jsonlite)
library(dplyr)
library(purrr)
library(tibble)

BASE_URL <- "https://clinicaltrials.gov/api/v2/studies"
PAGE_SIZE <- 1000L
OUT_DIR <- "data/raw"
STUDIES_OUT <- file.path(OUT_DIR, "ctgov_candidate_trials.csv")
ARMS_OUT <- file.path(OUT_DIR, "ctgov_candidate_trial_arms.csv")

dir.create(OUT_DIR, recursive = TRUE, showWarnings = FALSE)

`%||%` <- function(x, y) if (is.null(x)) y else x

#' Fetch every page of studies matching the query, following nextPageToken.
fetch_all_studies <- function(condition = "Non-Small Cell Lung Cancer",
                               overall_status = "COMPLETED",
                               page_size = PAGE_SIZE) {
  studies <- list()
  page_token <- NULL
  page_num <- 1L

  repeat {
    query <- list(
      "query.cond" = condition,
      "filter.overallStatus" = overall_status,
      "pageSize" = page_size,
      "format" = "json"
    )
    if (!is.null(page_token)) query$pageToken <- page_token

    resp <- GET(BASE_URL, query = query)
    stop_for_status(resp)

    parsed <- fromJSON(content(resp, "text", encoding = "UTF-8"),
                        simplifyVector = FALSE)

    n_this_page <- length(parsed$studies)
    message(sprintf("Fetched page %d: %d studies", page_num, n_this_page))
    studies <- c(studies, parsed$studies)

    page_token <- parsed$nextPageToken
    if (is.null(page_token) || n_this_page == 0L) break
    page_num <- page_num + 1L
  }

  studies
}

#' Pull the handful of fields Step 1 cares about out of one raw study record:
#' NCT ID, arms, phase, sponsor, and whether posted summary results exist.
extract_study_row <- function(study) {
  ps <- study$protocolSection

  nct_id <- ps$identificationModule$nctId %||% NA_character_
  brief_title <- ps$identificationModule$briefTitle %||% NA_character_

  phases <- ps$designModule$phases
  phase <- if (length(phases) > 0) paste(unlist(phases), collapse = "; ") else NA_character_

  overall_status <- ps$statusModule$overallStatus %||% NA_character_

  sponsor <- ps$sponsorCollaboratorsModule$leadSponsor$name %||% NA_character_

  conditions <- ps$conditionsModule$conditions
  conditions <- if (length(conditions) > 0) paste(unlist(conditions), collapse = "; ") else NA_character_

  enrollment <- ps$designModule$enrollmentInfo$count %||% NA_integer_

  arm_groups <- ps$armsInterventionsModule$armGroups
  n_arms <- length(arm_groups)

  has_results <- isTRUE(study$hasResults)

  tibble(
    nct_id = nct_id,
    brief_title = brief_title,
    phase = phase,
    overall_status = overall_status,
    sponsor = sponsor,
    conditions = conditions,
    enrollment_count = enrollment,
    n_arms = n_arms,
    has_posted_results = has_results
  )
}

#' Pull one row per treatment arm, keyed back to the parent NCT ID — needed
#' later to line up with Dataset 1's "Arm ID" linking key (Step 6).
extract_arm_rows <- function(study) {
  ps <- study$protocolSection
  nct_id <- ps$identificationModule$nctId %||% NA_character_
  arm_groups <- ps$armsInterventionsModule$armGroups

  if (length(arm_groups) == 0) {
    return(tibble(
      nct_id = nct_id, arm_label = NA_character_,
      arm_type = NA_character_, arm_description = NA_character_
    ))
  }

  map_dfr(arm_groups, function(arm) {
    tibble(
      nct_id = nct_id,
      arm_label = arm$label %||% NA_character_,
      arm_type = arm$type %||% NA_character_,
      arm_description = arm$description %||% NA_character_
    )
  })
}

message("Querying CT.gov v2 API for completed NSCLC trials...")
studies_raw <- fetch_all_studies()
message(sprintf("Total candidate trials retrieved: %d", length(studies_raw)))

studies_df <- map_dfr(studies_raw, extract_study_row)
arms_df <- map_dfr(studies_raw, extract_arm_rows)

write.csv(studies_df, STUDIES_OUT, row.names = FALSE)
write.csv(arms_df, ARMS_OUT, row.names = FALSE)

message(sprintf("Wrote %d trials to %s", nrow(studies_df), STUDIES_OUT))
message(sprintf("Wrote %d arm rows to %s", nrow(arms_df), ARMS_OUT))
