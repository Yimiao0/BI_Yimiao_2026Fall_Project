# Step 1 of the app: find trials on ClinicalTrials.gov and link each one to its
# results publication by PubMed ID, then look the papers up in Europe PMC (DOI,
# PubMed Central ID, open access). Trial search and filters follow
# scripts/data_collection_scripts/01_pull_ctgov_candidates.R.

CTGOV_URL <- "https://clinicaltrials.gov/api/v2/studies"
# Columns of the paper list, in order (also what the agent gets for each paper)
PAPER_COLUMNS <- c("nct_id", "pmid", "pmcid", "doi", "access_type", "citation")
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
ACCESS_KEEP_CHOICES <- c(
  "Open access (the AI agent can read these)" = "open",
  "All linked papers" = "all"
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
#' filtered on the server so the pull stays small. Warns if the search matches
#' more than max_studies trials, so the user knows a broad search will be slow.
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
        progress(0.02, sprintf(
          "Warning: the search matches %s trials, more than %s. This may take a long time; narrow the disease term or filters to speed it up.",
          format(total, big.mark = ","), format(max_studies, big.mark = ",")
        ))
      }
    }
    studies <- c(studies, page$studies)
    progress(0.02 + 0.13 * length(studies) / max(total, 1), sprintf("Downloaded %d/%d trial records", length(studies), total))
    query$countTotal <- NULL
    query$pageToken <- page$nextPageToken
    if (is.null(query$pageToken) || length(page$studies) == 0) break
  }
  studies
}

#' One row per study with the fields used for filtering and the paper list.
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

#' Link a trial to its paper: the first RESULT/DERIVED reference with a PubMed
#' ID. If no reference has one, the first reference whose citation text holds
#' a DOI.
link_trial <- function(nct_id, refs) {
  found <- function(r, pmid, doi) {
    tibble::tibble(nct_id = nct_id, publication_found = TRUE, ref_type = r$type,
                   pmid = pmid, doi = doi, citation = r$citation %||% NA_character_)
  }
  for (r in refs) {
    pmid <- r$pmid %||% NA_character_
    if (!is.na(pmid) && nzchar(pmid)) return(found(r, pmid, NA_character_))
  }
  for (r in refs) {
    doi <- doi_from_citation(r$citation %||% NA_character_)
    if (!is.na(doi)) return(found(r, NA_character_, doi))
  }
  tibble::tibble(nct_id = nct_id, publication_found = FALSE, ref_type = NA_character_,
                 pmid = NA_character_, doi = NA_character_, citation = NA_character_)
}

#' Look papers up in Europe PMC, up to 100 per request.
#' Returns a data frame with one row per paper: `access_type` (open_access =
#' open in Europe PMC with a PMCID /
#' not_open_access / not_in_europepmc / lookup_failed), `pmcid` (the PubMed
#' Central ID, which leads straight to the full text) and `doi` (NA if none).
#' Papers are matched by PMID, else DOI, else PMCID.
classify_access <- function(papers, progress = function(...) NULL, chunk_size = 100) {
  out <- rep(NA_character_, nrow(papers))
  pmcid_out <- rep(NA_character_, nrow(papers))
  doi_out <- rep(NA_character_, nrow(papers))
  citation_out <- rep(NA_character_, nrow(papers))
  pmid <- trimws(as.character(papers$pmid))
  doi <- tolower(trimws(as.character(papers$doi)))
  pmcid <- toupper(trimws(as.character(papers$pmcid %||% rep(NA, nrow(papers)))))
  by_pmid <- !is.na(pmid) & grepl("^[0-9]+$", pmid)
  by_doi <- !by_pmid & !is.na(doi) & nzchar(doi)
  by_pmcid <- !by_pmid & !by_doi & !is.na(pmcid) & grepl("^PMC[0-9]+$", pmcid)
  out[!by_pmid & !by_doi & !by_pmcid] <- "not_in_europepmc"

  # One request: returns the Europe PMC records, or NULL if it failed twice
  query_epmc <- function(q) {
    for (attempt in 1:2) {
      res <- tryCatch({
        resp <- httr::GET(EUROPEPMC_URL, query = list(
          query = q, resultType = "lite", format = "json", pageSize = 1000))
        httr::stop_for_status(resp)
        jsonlite::fromJSON(httr::content(resp, "text", encoding = "UTF-8"),
                           simplifyVector = FALSE)$resultList$result
      }, error = function(e) NULL)
      if (!is.null(res)) return(res)
      Sys.sleep(2)
    }
    NULL
  }
  # Open access = the agent can read it: open in Europe PMC and has a PMCID
  label <- function(rec) {
    if (identical(rec$isOpenAccess, "Y") && !is.null(rec$pmcid) && nzchar(rec$pmcid)) "open_access"
    else "not_open_access"
  }

  chunks <- function(rows) split(which(rows), ceiling(seq_len(sum(rows)) / chunk_size))
  jobs <- c(
    lapply(chunks(by_pmid), function(idx) list(idx = idx, key = "pmid", ids = pmid[idx],
      q = sprintf("(%s) AND SRC:MED", paste0("EXT_ID:", pmid[idx], collapse = " OR ")))),
    lapply(chunks(by_doi), function(idx) list(idx = idx, key = "doi", ids = doi[idx],
      q = paste0('DOI:"', doi[idx], '"', collapse = " OR "))),
    lapply(chunks(by_pmcid), function(idx) list(idx = idx, key = "pmcid", ids = tolower(pmcid[idx]),
      q = paste0("PMCID:", pmcid[idx], collapse = " OR ")))
  )
  for (j in seq_along(jobs)) {
    job <- jobs[[j]]
    recs <- query_epmc(job$q)
    if (is.null(recs)) {
      out[job$idx] <- "lookup_failed"
    } else {
      keys <- vapply(recs, function(r) tolower(r[[job$key]] %||% NA_character_), character(1))
      labels <- vapply(recs, label, character(1))
      pmcids <- vapply(recs, function(r) r$pmcid %||% NA_character_, character(1))
      rec_dois <- vapply(recs, function(r) r$doi %||% NA_character_, character(1))
      citations <- vapply(recs, epmc_citation, character(1))
      found <- match(job$ids, keys)
      out[job$idx] <- ifelse(is.na(found), "not_in_europepmc", labels[found])
      pmcid_out[job$idx] <- pmcids[found]
      doi_out[job$idx] <- rec_dois[found]
      citation_out[job$idx] <- citations[found]
    }
    progress(j / length(jobs), sprintf("Europe PMC lookup: request %d of %d", j, length(jobs)))
  }
  data.frame(access_type = out, pmcid = pmcid_out, doi = doi_out, citation = citation_out)
}

#' A citation with the title first, from a Europe PMC record:
#' "Title. Authors. Journal. Year;Volume:Pages." NA if the record has no title.
epmc_citation <- function(rec) {
  # Titles can hold HTML markup, e.g. "<i>nab</i>-Paclitaxel"; keep the text only
  plain <- function(x) {
    x <- x %||% ""
    for (i in 1:2) {  # markup can be encoded twice, e.g. "&amp;lt;i&amp;gt;"
      x <- gsub("&lt;", "<", gsub("&gt;", ">", gsub("&quot;", "\"", gsub("&#39;|&apos;", "'", x))))
      x <- gsub("&amp;", "&", x)
    }
    x <- gsub("</?[A-Za-z][A-Za-z0-9]*( [^<>]*)?/?>", "", x)  # tags only, so "R0 < 1" stays
    trimws(gsub("\\s+", " ", x))
  }
  rec$title <- plain(rec$title); rec$authorString <- plain(rec$authorString)
  rec$journalTitle <- plain(rec$journalTitle)
  title <- rec$title
  if (!nzchar(title)) return(NA_character_)
  end_dot <- function(x) if (grepl("[.?!]$", x)) x else paste0(x, ".")
  source <- paste0(rec$pubYear %||% "",
                   if (!is.null(rec$journalVolume)) paste0(";", rec$journalVolume) else "",
                   if (!is.null(rec$pageInfo)) paste0(":", rec$pageInfo) else "")
  parts <- c(title, rec$authorString %||% "", rec$journalTitle %||% "", source)
  parts <- trimws(parts[nzchar(trimws(parts))])
  paste(vapply(parts, end_dot, character(1)), collapse = " ")
}

#' Full Step 1 run. Returns a list with:
#'   papers    - one row per linked paper, columns PAPER_COLUMNS
#'   trials  - every candidate trial with its linkage result
#'   counts  - numbers for the flow summary
search_trials <- function(condition, statuses, phases, intervention_types, purposes,
                          require_enrollment = TRUE, max_studies = 5000,
                          progress = function(...) NULL) {
  progress(0, sprintf("Searching ClinicalTrials.gov for \"%s\"", condition))
  raw <- fetch_studies(condition, statuses, phases, max_studies, progress)
  if (length(raw) == 0) stop("No trials match this search.")

  studies_df <- purrr::map_dfr(raw, extract_study_row)
  keep <- filter_studies(studies_df, phases, intervention_types, purposes, require_enrollment)
  candidates <- studies_df[keep, ]
  raw_kept <- raw[keep]
  progress(0.18, sprintf("%d of %d trials meet the inclusion criteria", nrow(candidates), nrow(studies_df)))

  refs <- lapply(raw_kept, usable_references)
  links <- purrr::map2_dfr(candidates$nct_id, refs, link_trial)

  # Several trials can report in the same paper; keep the lowest NCT ID per
  # paper (by PubMed ID, or DOI when there's no PubMed ID).
  links <- links[order(links$nct_id), ]
  paper_key <- ifelse(!is.na(links$pmid), paste0("pmid:", links$pmid), paste0("doi:", tolower(links$doi)))
  dup <- links$publication_found & duplicated(paper_key)
  links$duplicate_paper <- dup
  progress(0.25, sprintf("%d trials link to a paper (%d papers after removing shared ones)",
                         sum(links$publication_found), sum(links$publication_found & !dup)))

  trials <- dplyr::left_join(candidates, links, by = "nct_id")
  papers <- trials[trials$publication_found & !trials$duplicate_paper,
                 c("nct_id", "pmid", "doi", "citation")]

  papers$access_type <- NA_character_
  papers$pmcid <- NA_character_
  if (nrow(papers) > 0) {
    epmc <- classify_access(papers, function(f, msg) progress(0.25 + 0.73 * f, msg))
    papers$access_type <- epmc$access_type
    papers$pmcid <- epmc$pmcid
    papers$doi <- ifelse(is.na(papers$doi), epmc$doi, papers$doi)
    # Title-first citation from Europe PMC; ClinicalTrials.gov's text if not found
    papers$citation <- ifelse(is.na(epmc$citation), papers$citation, epmc$citation)
  }
  papers <- papers[, PAPER_COLUMNS]

  counts <- list(
    matched = nrow(studies_df),
    candidates = nrow(candidates),
    no_publication = sum(!links$publication_found),
    duplicate_paper = sum(dup),
    papers = nrow(papers),
    open_access = sum(papers$access_type %in% "open_access"),
    access_failed = sum(papers$access_type %in% "lookup_failed")
  )
  progress(1, sprintf("Done: %d linked papers, %d open access", counts$papers, counts$open_access))
  list(papers = papers, trials = trials, counts = counts)
}

#' Keep papers by access type: "open" keeps open-access papers, "all" keeps all.
keep_by_access <- function(papers, keep = "all") {
  if (keep == "all") return(papers)
  papers[papers$access_type %in% "open_access", , drop = FALSE]
}

#' Excel file: the kept papers, every linked paper, every candidate trial,
#' and the search settings.
write_paper_workbook <- function(result, settings, path, kept = result$papers) {
  trials <- result$trials
  trials$included_in_paper_list <- trials$publication_found & !trials$duplicate_paper &
    trials$nct_id %in% kept$nct_id
  writexl::write_xlsx(list(
    input_papers = kept,
    all_linked_papers = result$papers,
    all_candidate_trials = trials,
    search_settings = settings
  ), path)
}
