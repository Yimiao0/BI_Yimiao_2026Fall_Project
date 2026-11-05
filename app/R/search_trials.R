# Step 1 of the app: find trials on ClinicalTrials.gov and link each one to its
# results publication (DOI). Same logic as
# scripts/data_collection_scripts/01_pull_ctgov_candidates.R and
# 01b_link_nct_to_pubmed.R, turned into functions that take the user's inputs.

CTGOV_URL <- "https://clinicaltrials.gov/api/v2/studies"
EUROPEPMC_URL <- "https://www.ebi.ac.uk/europepmc/webservices/rest/search"

PHASE_CHOICES <- c(
  "Early phase 1" = "EARLY_PHASE1", "Phase 1" = "PHASE1", "Phase 2" = "PHASE2",
  "Phase 3" = "PHASE3", "Phase 4" = "PHASE4"
)
STATUS_CHOICES <- c(
  "Completed" = "COMPLETED", "Terminated" = "TERMINATED",
  "Active, not recruiting" = "ACTIVE_NOT_RECRUITING", "Recruiting" = "RECRUITING",
  "Suspended" = "SUSPENDED", "Withdrawn" = "WITHDRAWN", "Unknown" = "UNKNOWN"
)
INTERVENTION_CHOICES <- c(
  "Drug" = "DRUG", "Biological" = "BIOLOGICAL", "Combination product" = "COMBINATION_PRODUCT",
  "Radiation" = "RADIATION", "Procedure" = "PROCEDURE", "Device" = "DEVICE",
  "Behavioral" = "BEHAVIORAL", "Dietary supplement" = "DIETARY_SUPPLEMENT",
  "Genetic" = "GENETIC", "Diagnostic test" = "DIAGNOSTIC_TEST", "Other" = "OTHER"
)
PURPOSE_CHOICES <- c(
  "Treatment" = "TREATMENT", "Prevention" = "PREVENTION", "Supportive care" = "SUPPORTIVE_CARE",
  "Diagnostic" = "DIAGNOSTIC", "Screening" = "SCREENING", "Basic science" = "BASIC_SCIENCE",
  "Health services research" = "HEALTH_SERVICES_RESEARCH", "Other" = "OTHER"
)

ctgov_get <- function(query) {
  resp <- httr::RETRY("GET", CTGOV_URL, query = query, times = 3, pause_base = 2, quiet = TRUE)
  httr::stop_for_status(resp)
  jsonlite::fromJSON(httr::content(resp, "text", encoding = "UTF-8"), simplifyVector = FALSE)
}

#' Fetch every study matching the search, following nextPageToken. Phase is
#' filtered on the server so the pull stays small. Stops if the search matches
#' more than max_studies trials, so a too-broad search fails fast.
fetch_studies <- function(condition, statuses, phases, max_studies, progress) {
  advanced <- "AREA[StudyType]INTERVENTIONAL"
  if (length(phases) > 0) {
    advanced <- sprintf("%s AND AREA[Phase](%s)", advanced, paste(phases, collapse = " OR "))
  }
  query <- list(
    "query.cond" = condition,
    "filter.overallStatus" = paste(statuses, collapse = ","),
    "filter.advanced" = advanced,
    "pageSize" = 1000L,
    "countTotal" = "true",
    "format" = "json"
  )

  studies <- list()
  total <- NA_integer_
  repeat {
    page <- ctgov_get(query)
    if (is.na(total)) {
      total <- page$totalCount %||% NA_integer_
      progress(0.02, sprintf("ClinicalTrials.gov: %s trials match the search", format(total, big.mark = ",")))
      if (!is.na(total) && total > max_studies) {
        stop(sprintf(
          "The search matches %s trials, more than the limit of %s. Narrow the disease term or filters, or raise the limit.",
          format(total, big.mark = ","), format(max_studies, big.mark = ",")
        ))
      }
    }
    studies <- c(studies, page$studies)
    progress(0.02 + 0.13 * length(studies) / max(total, 1), sprintf("Downloaded %d trial records", length(studies)))
    query$countTotal <- NULL
    query$pageToken <- page$nextPageToken
    if (is.null(query$pageToken) || length(page$studies) == 0) break
  }
  studies
}

#' One row per study with the fields used for filtering and the DOI list.
extract_study_row <- function(study) {
  ps <- study$protocolSection
  collapse <- function(x) if (length(x) > 0) paste(unlist(x), collapse = "; ") else NA_character_
  interventions <- ps$armsInterventionsModule$interventions
  types <- if (length(interventions) > 0) {
    collapse(sort(unique(vapply(interventions, function(iv) iv$type %||% NA_character_, character(1)))))
  } else NA_character_
  arm_groups <- ps$armsInterventionsModule$armGroups

  tibble::tibble(
    nct_id = ps$identificationModule$nctId %||% NA_character_,
    brief_title = ps$identificationModule$briefTitle %||% NA_character_,
    phase = collapse(ps$designModule$phases),
    primary_purpose = ps$designModule$designInfo$primaryPurpose %||% NA_character_,
    intervention_types = types,
    overall_status = ps$statusModule$overallStatus %||% NA_character_,
    sponsor = ps$sponsorCollaboratorsModule$leadSponsor$name %||% NA_character_,
    conditions = collapse(ps$conditionsModule$conditions),
    enrollment_count = as.integer(ps$designModule$enrollmentInfo$count %||% NA_integer_),
    n_arms = if (length(arm_groups) > 0) length(arm_groups) else NA_integer_,
    has_posted_results = isTRUE(study$hasResults)
  )
}

#' RESULT references first, then DERIVED; BACKGROUND references are never used.
usable_references <- function(study) {
  refs <- study$protocolSection$referencesModule$references %||% list()
  types <- vapply(refs, function(r) r$type %||% NA_character_, character(1))
  c(refs[types %in% "RESULT"], refs[types %in% "DERIVED"])
}

#' Apply the inclusion criteria together (a trial must pass all of them).
filter_studies <- function(studies_df, phases, intervention_types, purposes, require_enrollment) {
  has_any <- function(field, allowed) {
    vapply(strsplit(ifelse(is.na(field), "", field), "; ", fixed = TRUE),
           function(v) any(v %in% allowed), logical(1))
  }
  keep <- rep(TRUE, nrow(studies_df))
  if (length(phases) > 0) keep <- keep & has_any(studies_df$phase, phases)
  if (length(intervention_types) > 0) keep <- keep & has_any(studies_df$intervention_types, intervention_types)
  if (length(purposes) > 0) keep <- keep & studies_df$primary_purpose %in% purposes
  if (require_enrollment) keep <- keep & !is.na(studies_df$enrollment_count)
  keep
}

doi_from_citation <- function(citation) {
  if (is.na(citation)) return(NA_character_)
  m <- regmatches(citation, regexpr("10\\.[0-9]{4,9}/\\S+", citation, perl = TRUE))
  if (length(m) == 0 || !nzchar(m)) return(NA_character_)
  sub("[.,;:)]+$", "", m)
}

#' Look up DOIs for many PMIDs at once (PubMed esummary, 200 per request).
#' Returns a named character vector: PMID -> DOI (NA when PubMed has none).
fetch_dois_for_pmids <- function(pmids, progress) {
  pmids <- unique(pmids[!is.na(pmids)])
  out <- setNames(rep(NA_character_, length(pmids)), pmids)
  if (length(pmids) == 0) return(out)

  key <- Sys.getenv("NCBI_API_KEY")
  if (nzchar(key)) rentrez::set_entrez_key(key)
  delay <- if (nzchar(key)) 0.11 else 0.35

  batches <- split(pmids, ceiling(seq_along(pmids) / 200))
  for (i in seq_along(batches)) {
    ids <- batches[[i]]
    summ <- tryCatch(rentrez::entrez_summary(db = "pubmed", id = ids, always_return_list = TRUE),
                     error = function(e) NULL)
    if (!is.null(summ)) {
      for (s in summ) {
        ai <- s$articleids
        if (!is.null(ai) && !is.null(s$uid)) {
          doi <- ai$value[ai$idtype == "doi"]
          if (length(doi) > 0) out[[s$uid]] <- doi[1]
        }
      }
    }
    progress(0.20 + 0.45 * i / length(batches), sprintf("PubMed DOI lookup: batch %d of %d", i, length(batches)))
    Sys.sleep(delay)
  }
  out
}

#' Pick the first RESULT/DERIVED reference that yields a DOI (from PubMed via
#' its PMID, else from its citation text).
link_trial <- function(nct_id, refs, pmid_dois) {
  for (r in refs) {
    pmid <- r$pmid %||% NA_character_
    citation <- r$citation %||% NA_character_
    doi <- if (!is.na(pmid) && pmid %in% names(pmid_dois)) pmid_dois[[pmid]] else NA_character_
    if (is.na(doi)) doi <- doi_from_citation(citation)
    if (!is.na(doi)) {
      return(tibble::tibble(nct_id = nct_id, publication_found = TRUE, ref_type = r$type,
                            pmid = pmid, doi = doi, citation = citation))
    }
  }
  tibble::tibble(nct_id = nct_id, publication_found = FALSE, ref_type = NA_character_,
                 pmid = NA_character_, doi = NA_character_, citation = NA_character_)
}

#' Classify access with Europe PMC: open_access / free_access / paywalled /
#' not_in_europepmc / lookup_failed. Same rules as 02_access_and_screen_europepmc.R.
classify_access <- function(doi) {
  rec <- tryCatch({
    resp <- httr::GET(EUROPEPMC_URL, query = list(
      query = sprintf('DOI:"%s"', doi), resultType = "core", format = "json"))
    httr::stop_for_status(resp)
    jsonlite::fromJSON(httr::content(resp, "text", encoding = "UTF-8"),
                       simplifyVector = FALSE)$resultList$result
  }, error = function(e) e)
  if (inherits(rec, "error")) return("lookup_failed")
  if (length(rec) == 0) return("not_in_europepmc")
  rec <- rec[[1]]
  urls <- rec$fullTextUrlList$fullTextUrl %||% list()
  codes <- vapply(urls, function(u) u$availabilityCode %||% NA_character_, character(1))
  if (identical(rec$isOpenAccess, "Y")) "open_access"
  else if (any(codes %in% c("OA", "F")) || identical(rec$inEPMC, "Y")) "free_access"
  else "paywalled"
}

#' Full Step 1 run. Returns a list with:
#'   dois    - one row per publication, columns as in build_agent/input_dois.xlsx
#'   trials  - every candidate trial with its linkage result
#'   counts  - numbers for the flow summary
search_trials <- function(condition, statuses, phases, intervention_types, purposes,
                          require_enrollment = TRUE, check_access = TRUE,
                          max_studies = 5000, progress = function(...) NULL) {
  progress(0, sprintf("Searching ClinicalTrials.gov for \"%s\"", condition))
  raw <- fetch_studies(condition, statuses, phases, max_studies, progress)
  if (length(raw) == 0) stop("No trials match this search.")

  studies_df <- purrr::map_dfr(raw, extract_study_row)
  keep <- filter_studies(studies_df, phases, intervention_types, purposes, require_enrollment)
  candidates <- studies_df[keep, ]
  raw_kept <- raw[keep]
  progress(0.18, sprintf("%d of %d trials meet the inclusion criteria", nrow(candidates), nrow(studies_df)))

  refs <- lapply(raw_kept, usable_references)
  all_pmids <- unlist(lapply(refs, function(rs) vapply(rs, function(r) r$pmid %||% NA_character_, character(1))))
  pmid_dois <- fetch_dois_for_pmids(all_pmids, progress)

  links <- purrr::map2_dfr(candidates$nct_id, refs, link_trial, pmid_dois = pmid_dois)

  # Several trials can report in the same paper; keep the lowest NCT ID per DOI.
  links <- links[order(links$nct_id), ]
  dup <- !is.na(links$doi) & duplicated(tolower(links$doi))
  links$duplicate_doi <- dup

  trials <- dplyr::left_join(candidates, links, by = "nct_id")
  dois <- trials[trials$publication_found & !trials$duplicate_doi,
                 c("nct_id", "pmid", "doi", "citation")]

  dois$access_type <- NA_character_
  if (check_access && nrow(dois) > 0) {
    for (i in seq_len(nrow(dois))) {
      dois$access_type[i] <- classify_access(dois$doi[i])
      if (i %% 10 == 0 || i == nrow(dois)) {
        progress(0.70 + 0.28 * i / nrow(dois), sprintf("Europe PMC access check: %d of %d", i, nrow(dois)))
      }
      Sys.sleep(0.15)
    }
  }
  dois <- dois[, c("nct_id", "pmid", "doi", "access_type", "citation")]

  counts <- list(
    matched = nrow(studies_df),
    candidates = nrow(candidates),
    no_publication = sum(!links$publication_found),
    duplicate_doi = sum(dup),
    dois = nrow(dois)
  )
  progress(1, sprintf("Done: %d publications with a DOI", nrow(dois)))
  list(dois = dois, trials = trials, counts = counts)
}

#' Write the DOI workbook. Sheet 1 matches the agent's input format.
write_doi_workbook <- function(result, settings, path) {
  trials <- result$trials
  trials$included_in_doi_list <- trials$publication_found & !trials$duplicate_doi
  writexl::write_xlsx(list(
    input_dois = result$dois,
    all_candidate_trials = trials,
    search_settings = settings
  ), path)
}
