# Step 1 (nsclc_data_collection_workflow.md): Pull candidate trials via the
# ClinicalTrials.gov v2 REST API.
#
# Stage 1: broad pull (NSCLC + COMPLETED + INTERVENTIONAL only) -> raw CSV.
# Stage 2: tabulate intervention types found, then keep only studies with
# at least one drug-like type -> filtered candidate CSV + audit tabulation.

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
RAW_OUT <- file.path(OUT_DIR, "ctgov_all_completed_interventional.csv")
TABULATION_OUT <- file.path(OUT_DIR, "ctgov_intervention_type_tabulation.csv")
STUDIES_OUT <- file.path(OUT_DIR, "ctgov_candidate_trials.csv")
ARMS_OUT <- file.path(OUT_DIR, "ctgov_candidate_trial_arms.csv")

# Keep a study if any of its intervention types is in this set. Adjust based
# on the tabulation printed/written by Stage 2.
KEEP_IF_ANY_TYPE <- c("DRUG", "BIOLOGICAL", "COMBINATION_PRODUCT", "GENETIC")

dir.create(OUT_DIR, recursive = TRUE, showWarnings = FALSE)

`%||%` <- function(x, y) if (is.null(x)) y else x

#' Fetch every page of studies matching the query, following nextPageToken.
fetch_all_studies <- function(condition = "Non-Small Cell Lung Cancer",
                               overall_status = "COMPLETED",
                               advanced_filter = "AREA[StudyType]INTERVENTIONAL",
                               page_size = PAGE_SIZE) {
  studies <- list()
  page_token <- NULL
  page_num <- 1L

  repeat {
    query <- list(
      "query.cond" = condition,
      "filter.overallStatus" = overall_status,
      "filter.advanced" = advanced_filter,
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

#' Pull the handful of fields Step 1 cares about out of one raw study record.
extract_study_row <- function(study) {
  ps <- study$protocolSection

  nct_id <- ps$identificationModule$nctId %||% NA_character_
  brief_title <- ps$identificationModule$briefTitle %||% NA_character_

  phases <- ps$designModule$phases
  phase <- if (length(phases) > 0) paste(unlist(phases), collapse = "; ") else NA_character_

  primary_purpose <- ps$designModule$designInfo$primaryPurpose %||% NA_character_

  overall_status <- ps$statusModule$overallStatus %||% NA_character_

  sponsor <- ps$sponsorCollaboratorsModule$leadSponsor$name %||% NA_character_

  conditions <- ps$conditionsModule$conditions
  conditions <- if (length(conditions) > 0) paste(unlist(conditions), collapse = "; ") else NA_character_

  enrollment <- ps$designModule$enrollmentInfo$count %||% NA_integer_

  arm_groups <- ps$armsInterventionsModule$armGroups
  n_arms <- length(arm_groups)

  interventions <- ps$armsInterventionsModule$interventions
  intervention_types <- if (length(interventions) > 0) {
    types <- map_chr(interventions, function(iv) iv$type %||% NA_character_)
    paste(sort(unique(types)), collapse = "; ")
  } else {
    NA_character_
  }

  has_results <- isTRUE(study$hasResults)

  tibble(
    nct_id = nct_id,
    brief_title = brief_title,
    phase = phase,
    primary_purpose = primary_purpose,
    intervention_types = intervention_types,
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

## Stage 1: broad pull ----------------------------------------------------

message("Stage 1: querying CT.gov v2 API for completed NSCLC interventional trials (broad, unfiltered)...")
studies_raw <- fetch_all_studies()
message(sprintf("Total candidate trials retrieved: %d", length(studies_raw)))

studies_df <- map_dfr(studies_raw, extract_study_row)
arms_df_all <- map_dfr(studies_raw, extract_arm_rows)

write.csv(studies_df, RAW_OUT, row.names = FALSE)
message(sprintf("Wrote %d unfiltered trials to %s", nrow(studies_df), RAW_OUT))

## Stage 2: tabulate intervention types, then include/exclude ------------

message("\nStage 2: tabulating intervention types across the raw pool...")
type_tabulation <- studies_df %>%
  mutate(intervention_types = ifelse(is.na(intervention_types), "NONE_LISTED", intervention_types)) %>%
  count(intervention_types, name = "n_studies", sort = TRUE) %>%
  mutate(
    kept = vapply(
      strsplit(intervention_types, "; "),
      function(types) any(types %in% KEEP_IF_ANY_TYPE),
      logical(1)
    )
  )

print(type_tabulation, n = Inf)
write.csv(type_tabulation, TABULATION_OUT, row.names = FALSE)
message(sprintf("Wrote intervention-type tabulation to %s", TABULATION_OUT))

is_drug_like <- function(intervention_types) {
  if (is.na(intervention_types)) return(FALSE)
  types <- strsplit(intervention_types, "; ")[[1]]
  any(types %in% KEEP_IF_ANY_TYPE)
}

studies_df <- studies_df %>%
  mutate(kept = vapply(intervention_types, is_drug_like, logical(1)))

n_excluded <- sum(!studies_df$kept)
message(sprintf(
  "\nExcluding %d / %d studies with no drug-like intervention type (%s)",
  n_excluded, nrow(studies_df), paste(KEEP_IF_ANY_TYPE, collapse = ", ")
))

studies_kept_df <- studies_df %>% filter(kept) %>% select(-kept)
kept_ids <- studies_kept_df$nct_id
arms_df <- arms_df_all %>% filter(nct_id %in% kept_ids)

write.csv(studies_kept_df, STUDIES_OUT, row.names = FALSE)
write.csv(arms_df, ARMS_OUT, row.names = FALSE)

message(sprintf("Wrote %d candidate trials to %s", nrow(studies_kept_df), STUDIES_OUT))
message(sprintf("Wrote %d arm rows to %s", nrow(arms_df), ARMS_OUT))
