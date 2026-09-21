# Step 2 (nsclc_data_collection_workflow.md): Link each NCT ID from Step 1 to
# its primary publication. Priority cascade, stopping at first success:
#
#   1. CT.gov's own linked references (referencesModule) -- batched, free
#      (curated or auto-linked by NLM).
#   2. PubMed exact match: NCT_ID[si].
#
# If neither stage finds a linked publication, the trial is marked as having
# no publication found. 
#
# Input:  data/raw/step1_ctgov_candidate_trials.csv (from 01_pull_ctgov_candidates.R)
# Output: data/raw/step2_nct_publication_links.csv

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
LINKS_OUT <- file.path(OUT_DIR, "step2_nct_publication_links.csv")
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

## ---- Stage 1: CT.gov linked references (batched) ----------------------

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
      warning(sprintf("CT.gov context batch %d/%d failed (%s) -- skipping these %d IDs, they'll fall through to the PubMed exact-match stage",
                       i, length(batches), conditionMessage(e), length(ids)))
      list()
    })
    results <- c(results, batch_result)
    message(sprintf("  CT.gov context batch %d/%d (%d IDs)", i, length(batches), length(ids)))
    Sys.sleep(0.2)
  }

  results
}

#' Pull the fields Stage 1 needs out of one raw CT.gov study record.
extract_context_row <- function(study) {
  ps <- study$protocolSection
  nct_id <- ps$identificationModule$nctId %||% NA_character_

  refs <- ps$referencesModule$references
  ref_pmids <- if (length(refs) > 0) {
    pmids <- map_chr(refs, function(r) r$pmid %||% NA_character_)
    pmids[!is.na(pmids)]
  } else character(0)
  ref_citation <- if (length(refs) > 0) refs[[1]]$citation %||% NA_character_ else NA_character_
  # Full referencesModule.references list (type/pmid/citation per entry), as
  # returned by CT.gov, so the original reference link/data isn't lost even
  # though only the first pmid/citation are used downstream.
  ref_raw <- if (length(refs) > 0) as.character(toJSON(refs, auto_unbox = TRUE)) else NA_character_

  tibble(
    nct_id = nct_id,
    ctgov_ref_pmids = if (length(ref_pmids) > 0) paste(ref_pmids, collapse = ";") else NA_character_,
    ctgov_ref_citation = ref_citation,
    ctgov_ref_raw = ref_raw
  )
}

## ---- Stage 2: PubMed exact match ([si]) --------------------------------

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

#' Look up a single PMID's DOI via entrez_summary (used for pmids we already
#' resolved via a CT.gov reference or the exact [si] match, neither of which
#' otherwise surfaces a DOI).
fetch_doi_for_pmid <- function(pmid, retries = 1L) {
  summ <- tryCatch(entrez_summary(db = "pubmed", id = pmid), error = function(e) e)
  if (inherits(summ, "error")) {
    if (retries > 0) { Sys.sleep(1); return(fetch_doi_for_pmid(pmid, retries - 1L)) }
    return(NA_character_)
  }
  extract_doi(summ)
}

search_pubmed_si <- function(nct_id, retries = 1L) {
  result <- tryCatch(
    entrez_search(db = "pubmed", term = sprintf("%s[si]", nct_id), retmax = 5),
    error = function(e) e
  )
  if (inherits(result, "error")) {
    if (retries > 0) { Sys.sleep(1); return(search_pubmed_si(nct_id, retries - 1L)) }
    return(character(0))
  }
  result$ids
}

## ---- Driver: run the cascade for one NCT ID ----------------------------

link_one_trial <- function(nct_id, ctgov_ref_pmids, ctgov_ref_citation, ctgov_ref_raw) {
  # 1. CT.gov linked reference -- look up its DOI via PubMed (using the
  # first PMID if the reference lists more than one).
  if (!is.na(ctgov_ref_pmids)) {
    first_pmid <- strsplit(ctgov_ref_pmids, ";")[[1]][1]
    ref_doi <- fetch_doi_for_pmid(first_pmid)
    Sys.sleep(PUBMED_DELAY)
    if (is.na(ref_doi)) ref_doi <- extract_doi_from_citation(ctgov_ref_citation)
    return(tibble(
      nct_id = nct_id, match_source = "ctgov_reference", confidence = "found",
      pmid = ctgov_ref_pmids, doi = ref_doi, title_or_citation = ctgov_ref_citation,
      ctgov_ref_raw = ctgov_ref_raw
    ))
  }

  # 2. PubMed exact [si]
  si_ids <- search_pubmed_si(nct_id)
  Sys.sleep(PUBMED_DELAY)
  if (length(si_ids) > 0) {
    si_doi <- fetch_doi_for_pmid(si_ids[1])
    Sys.sleep(PUBMED_DELAY)
    return(tibble(
      nct_id = nct_id, match_source = "pubmed_si", confidence = "found",
      pmid = paste(si_ids, collapse = ";"), doi = si_doi, title_or_citation = NA_character_,
      ctgov_ref_raw = ctgov_ref_raw
    ))
  }

  tibble(
    nct_id = nct_id, match_source = "none", confidence = "not_found",
    pmid = NA_character_, doi = NA_character_, title_or_citation = NA_character_,
    ctgov_ref_raw = ctgov_ref_raw
  )
}

## ---- Run ----------------------------------------------------------------

message("Reading candidate trials from Step 1...")
studies_df <- read.csv(STUDIES_IN, stringsAsFactors = FALSE)
nct_ids <- unique(studies_df$nct_id[!is.na(studies_df$nct_id)])
n_total <- length(nct_ids)

message(sprintf("Stage 1: batch-fetching CT.gov references for %d NCT IDs...", n_total))
ctgov_raw <- fetch_ctgov_context(nct_ids)
ctgov_context <- map_dfr(ctgov_raw, extract_context_row)

message(sprintf("Stage 2: running PubMed exact-match search for NCT IDs with no CT.gov reference (%d total)...", n_total))

links_list <- vector("list", n_total)
for (i in seq_len(n_total)) {
  ctx <- ctgov_context[ctgov_context$nct_id == nct_ids[i], ]
  links_list[[i]] <- link_one_trial(
    nct_id = nct_ids[i],
    ctgov_ref_pmids = ctx$ctgov_ref_pmids[1],
    ctgov_ref_citation = ctx$ctgov_ref_citation[1],
    ctgov_ref_raw = ctx$ctgov_ref_raw[1]
  )

  if (i %% CHECKPOINT_EVERY == 0 || i == n_total) {
    message(sprintf("  ...%d / %d NCT IDs linked", i, n_total))
    bind_rows(links_list[seq_len(i)]) %>% write.csv(LINKS_OUT, row.names = FALSE)
  }
}

links_df <- bind_rows(links_list)

summary_tbl <- links_df %>% count(match_source, confidence, sort = TRUE)
n_found <- sum(links_df$confidence == "found")
n_not_found <- sum(links_df$confidence == "not_found")

message("\n--- Publication linkage summary ---")
print(summary_tbl, n = Inf)
message(sprintf("\nPublication found (CT.gov ref / PubMed exact): %d (%.1f%%)", n_found, 100 * n_found / n_total))
message(sprintf("No publication found:                           %d (%.1f%%)", n_not_found, 100 * n_not_found / n_total))
message(sprintf("\nWrote linkage table to %s", LINKS_OUT))
