# Step 1 Stage 3 (nsclc_data_collection_workflow.md): Link each candidate NCT ID
# to its primary publication via CT.gov's own linked references
# (referencesModule), batched. Reference priority: RESULT (sponsor-marked
# results paper), then DERIVED (auto-linked by NLM from PubMed); BACKGROUND
# references are never used. The DOI comes from PubMed via the reference's
# PMID, or else from the reference's citation text.
#
# If no RESULT/DERIVED reference yields a DOI (via PubMed or its citation), the
# trial is marked as having no publication found.
#
# Input:  data/raw/step1_ctgov_candidate_trials.csv (from 01_pull_ctgov_candidates.R)
# Output: data/raw/step1_nct_publication_links.csv

required_pkgs <- c("httr", "jsonlite", "rentrez", "dplyr", "purrr", "tibble")
missing_pkgs <- setdiff(required_pkgs, rownames(installed.packages()))
if (length(missing_pkgs) > 0) install.packages(missing_pkgs)

library(httr)
library(jsonlite)
library(rentrez)
library(dplyr)
library(purrr)
library(tibble)

IN_DIR <- "data/raw"
STUDIES_IN <- file.path(IN_DIR, "step1_ctgov_candidate_trials.csv")
OUT_DIR <- "data/raw"
LINKS_OUT <- file.path(OUT_DIR, "step1_nct_publication_links.csv")
CHECKPOINT_EVERY <- 100L
CTGOV_BATCH_SIZE <- 250L

dir.create(OUT_DIR, recursive = TRUE, showWarnings = FALSE)

`%||%` <- function(x, y) if (is.null(x)) y else x

api_key <- Sys.getenv("NCBI_API_KEY", unset = NA)
if (!is.na(api_key) && nzchar(api_key)) {
  set_entrez_key(api_key)
  PUBMED_DELAY <- 0.11
} else {
  PUBMED_DELAY <- 0.35
}

## ---- CT.gov linked references (batched) --------------------------------

#' Batch-fetch referencesModule for a vector of NCT IDs, CTGOV_BATCH_SIZE at a
#' time (avoids the GET URL-length limit -- 1000 IDs in one request 414s, 500
#' is safe).
fetch_ctgov_context <- function(nct_ids, batch_size = CTGOV_BATCH_SIZE) {
  batches <- split(nct_ids, ceiling(seq_along(nct_ids) / batch_size))
  results <- list()

  for (i in seq_along(batches)) {
    ids <- batches[[i]]
    batch_result <- tryCatch({
      resp <- GET(
        "https://clinicaltrials.gov/api/v2/studies",
        query = list(
          "filter.ids" = paste(ids, collapse = ","),
          "pageSize" = length(ids),
          "fields" = paste(
            "protocolSection.identificationModule.nctId",
            "protocolSection.referencesModule",
            sep = ","
          ),
          "format" = "json"
        )
      )
      stop_for_status(resp)
      fromJSON(content(resp, "text", encoding = "UTF-8"), simplifyVector = FALSE)$studies
    }, error = function(e) {
      warning(sprintf("CT.gov context batch %d/%d failed (%s) -- skipping these %d IDs, they'll be marked as no publication found",
                       i, length(batches), conditionMessage(e), length(ids)))
      list()
    })
    results <- c(results, batch_result)
    message(sprintf("  CT.gov context batch %d/%d (%d IDs)", i, length(batches), length(ids)))
    Sys.sleep(0.2)
  }

  results
}

#' Pull the reference fields out of one raw CT.gov study record. Keeps only
#' RESULT and DERIVED references (BACKGROUND references are context, not
#' reports of this trial), RESULT first, then DERIVED, each in CT.gov order.
extract_context_row <- function(study) {
  ps <- study$protocolSection
  nct_id <- ps$identificationModule$nctId %||% NA_character_

  refs <- ps$referencesModule$references %||% list()
  ref_types <- map_chr(refs, function(r) r$type %||% NA_character_)
  usable <- c(refs[ref_types %in% "RESULT"], refs[ref_types %in% "DERIVED"])

  # Full referencesModule.references list (type/pmid/citation per entry), as
  # returned by CT.gov, so the original reference data isn't lost even
  # though only one reference is used downstream.
  ref_raw <- if (length(refs) > 0) as.character(toJSON(refs, auto_unbox = TRUE)) else NA_character_

  tibble(
    nct_id = nct_id,
    usable_refs = list(usable),
    ctgov_ref_raw = ref_raw
  )
}

## ---- DOI lookup ---------------------------------------------------------

#' Pull the DOI (if any) out of an entrez_summary() result -- PubMed's
#' articleids table carries it as the row with idtype == "doi".
extract_doi <- function(summ) {
  if (is.null(summ) || is.null(summ$articleids)) return(NA_character_)
  doi <- summ$articleids$value[summ$articleids$idtype == "doi"]
  if (length(doi) > 0) doi[1] else NA_character_
}

#' Fallback: pull a DOI directly out of a citation string. entrez_summary()
#' sometimes omits the doi articleid even though the citation text (e.g. from
#' a CT.gov reference) spells it out, so this covers those cases.
extract_doi_from_citation <- function(citation) {
  if (is.na(citation)) return(NA_character_)
  m <- regmatches(citation, regexpr("10\\.[0-9]{4,9}/\\S+", citation, perl = TRUE))
  if (length(m) == 0 || !nzchar(m)) return(NA_character_)
  sub("[.,;:)]+$", "", m)
}

#' Look up a single PMID's DOI via entrez_summary (the CT.gov reference
#' only surfaces the PMID, not a DOI).
fetch_doi_for_pmid <- function(pmid, retries = 1L) {
  summ <- tryCatch(entrez_summary(db = "pubmed", id = pmid), error = function(e) e)
  if (inherits(summ, "error")) {
    if (retries > 0) { Sys.sleep(1); return(fetch_doi_for_pmid(pmid, retries - 1L)) }
    return(NA_character_)
  }
  extract_doi(summ)
}

## ---- Driver: link one NCT ID --------------------------------------------

#' Walk the RESULT-then-DERIVED references and link the first one that yields
#' a DOI. DOI: from PubMed if the reference has a PMID, falling back to a DOI
#' in that same reference's citation text. A reference with no DOI is skipped.
link_one_trial <- function(nct_id, usable_refs, ctgov_ref_raw) {
  all_pmids <- unique(na.omit(map_chr(usable_refs, function(r) r$pmid %||% NA_character_)))
  pmids_all <- if (length(all_pmids) > 0) paste(all_pmids, collapse = ";") else NA_character_

  for (r in usable_refs) {
    ref_pmid <- r$pmid %||% NA_character_
    ref_citation <- r$citation %||% NA_character_

    ref_doi <- NA_character_
    if (!is.na(ref_pmid)) {
      ref_doi <- fetch_doi_for_pmid(ref_pmid)
      Sys.sleep(PUBMED_DELAY)
    }
    if (is.na(ref_doi)) ref_doi <- extract_doi_from_citation(ref_citation)

    if (!is.na(ref_doi)) {
      return(tibble(
        nct_id = nct_id, match_source = "ctgov_reference", confidence = "found",
        ref_type = r$type, pmid = ref_pmid, doi = ref_doi, title_or_citation = ref_citation,
        pmids_all = pmids_all, ctgov_ref_raw = ctgov_ref_raw
      ))
    }
  }

  tibble(
    nct_id = nct_id, match_source = "none", confidence = "not_found",
    ref_type = NA_character_, pmid = NA_character_, doi = NA_character_, title_or_citation = NA_character_,
    pmids_all = pmids_all, ctgov_ref_raw = ctgov_ref_raw
  )
}

## ---- Run ----------------------------------------------------------------

message("Reading candidate trials from Step 1...")
studies_df <- read.csv(STUDIES_IN, stringsAsFactors = FALSE)
nct_ids <- unique(studies_df$nct_id[!is.na(studies_df$nct_id)])
n_total <- length(nct_ids)

message(sprintf("Batch-fetching CT.gov references for %d NCT IDs...", n_total))
ctgov_raw <- fetch_ctgov_context(nct_ids)
ctgov_context <- map_dfr(ctgov_raw, extract_context_row)

message(sprintf("Linking %d NCT IDs and looking up DOIs...", n_total))

links_list <- vector("list", n_total)
for (i in seq_len(n_total)) {
  ctx <- ctgov_context[ctgov_context$nct_id == nct_ids[i], ]
  links_list[[i]] <- link_one_trial(
    nct_id = nct_ids[i],
    usable_refs = if (nrow(ctx) > 0) ctx$usable_refs[[1]] else list(),
    ctgov_ref_raw = if (nrow(ctx) > 0) ctx$ctgov_ref_raw[1] else NA_character_
  )

  if (i %% CHECKPOINT_EVERY == 0 || i == n_total) {
    message(sprintf("  ...%d / %d NCT IDs linked", i, n_total))
    bind_rows(links_list[seq_len(i)]) %>% write.csv(LINKS_OUT, row.names = FALSE)
  }
}

links_df <- bind_rows(links_list)

# Several trials can link to the same paper (pooled reports, reviews,
# secondary analyses). Keep only the earliest-registered trial (lowest NCT ID)
# per DOI (case-insensitive); rows without a DOI are never treated as
# duplicates. Row order is otherwise unchanged.
doi_key <- tolower(links_df$doi)
by_nct <- order(links_df$nct_id)
is_dup_doi <- logical(nrow(links_df))
is_dup_doi[by_nct] <- !is.na(doi_key[by_nct]) & duplicated(doi_key[by_nct])
message(sprintf("\nDropping %d records whose DOI duplicates an earlier record", sum(is_dup_doi)))
links_df <- links_df[!is_dup_doi, ]
write.csv(links_df, LINKS_OUT, row.names = FALSE)
n_total <- nrow(links_df)

summary_tbl <- links_df %>% count(match_source, confidence, sort = TRUE)
n_found <- sum(links_df$confidence == "found")
n_not_found <- sum(links_df$confidence == "not_found")

message("\n--- Publication linkage summary ---")
print(summary_tbl, n = Inf)
message(sprintf("\nPublication found (CT.gov reference with DOI): %d (%.1f%%)", n_found, 100 * n_found / n_total))
message(sprintf("No publication found:                         %d (%.1f%%)", n_not_found, 100 * n_not_found / n_total))
message(sprintf("\nWrote linkage table to %s", LINKS_OUT))
