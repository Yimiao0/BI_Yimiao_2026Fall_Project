# Step 2 (nsclc_data_collection_workflow.md): Link each NCT ID from Step 1 to
# its primary publication. Priority cascade, stopping at first success:
#
#   1. CT.gov's own linked references (referencesModule) -- batched, free,
#      high confidence (curated or auto-linked by NLM).
#   2. PubMed exact match: NCT_ID[si] -- high confidence.
#   3. PubMed fuzzy match: drug name(s) + "non-small cell lung cancer" -- low
#      confidence, candidate only.
#   4. OpenAlex full-text search for the NCT number -- low confidence
#      (can surface papers that merely cite the trial, not its own report).
#   5. OpenAlex topic search: drug name(s) + condition -- low confidence,
#      last resort.
#
# Crossref metadata search was tested and dropped: its relevance ranking
# failed to surface a paper Crossref has indexed even by DOI (verified against
# the NCT00638937 case study), so it added no real recall over OpenAlex here.
#
# Full-text verification of low-confidence candidates and any Google Scholar
# fallback stay manual (Step 3) -- not scriptable at this precision.
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
OPENALEX_DELAY <- 0.2

## ---- Stage 1: CT.gov linked references (batched) ----------------------

#' Batch-fetch referencesModule + intervention/condition/phase context for a
#' vector of NCT IDs, CTGOV_BATCH_SIZE at a time (avoids the GET URL-length
#' limit -- 1000 IDs in one request 414s, 500 is safe).
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
            "protocolSection.identificationModule.briefTitle",
            "protocolSection.referencesModule",
            "protocolSection.armsInterventionsModule.interventions",
            "protocolSection.conditionsModule.conditions",
            sep = ","
          ),
          "format" = "json"
        )
      )
      stop_for_status(resp)
      fromJSON(content(resp, "text", encoding = "UTF-8"), simplifyVector = FALSE)$studies
    }, error = function(e) {
      warning(sprintf("CT.gov context batch %d/%d failed (%s) -- skipping these %d IDs, they'll fall through to PubMed/OpenAlex with no drug-name context",
                       i, length(batches), conditionMessage(e), length(ids)))
      list()
    })
    results <- c(results, batch_result)
    message(sprintf("  CT.gov context batch %d/%d (%d IDs)", i, length(batches), length(ids)))
    Sys.sleep(0.2)
  }

  results
}

#' Pull the fields Stage 1 (references) and Stages 3/5 (drug names, condition)
#' need out of one raw CT.gov study record.
extract_context_row <- function(study) {
  ps <- study$protocolSection
  nct_id <- ps$identificationModule$nctId %||% NA_character_
  brief_title <- ps$identificationModule$briefTitle %||% NA_character_

  refs <- ps$referencesModule$references
  ref_pmids <- if (length(refs) > 0) {
    pmids <- map_chr(refs, function(r) r$pmid %||% NA_character_)
    pmids[!is.na(pmids)]
  } else character(0)
  ref_citation <- if (length(refs) > 0) refs[[1]]$citation %||% NA_character_ else NA_character_

  interventions <- ps$armsInterventionsModule$interventions
  drug_names <- if (length(interventions) > 0) {
    is_drug_like <- map_lgl(interventions, function(iv) {
      (iv$type %||% "") %in% c("DRUG", "BIOLOGICAL", "COMBINATION_PRODUCT", "GENETIC")
    })
    names <- map_chr(interventions[is_drug_like], function(iv) iv$name %||% NA_character_)
    unique(names[!is.na(names)])
  } else character(0)

  tibble(
    nct_id = nct_id,
    brief_title = brief_title,
    ctgov_ref_pmids = if (length(ref_pmids) > 0) paste(ref_pmids, collapse = ";") else NA_character_,
    ctgov_ref_citation = ref_citation,
    drug_names = if (length(drug_names) > 0) paste(drug_names, collapse = "; ") else NA_character_
  )
}

## ---- Stage 2/3: PubMed exact ([si]) and fuzzy (drug + condition) -------

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

# Generic backbone/comparator agents excluded from the fuzzy query below --
# OR'ing these in makes the query match almost any NSCLC trial paper (found
# via spot-check: 248/1041 initial fuzzy "matches" collapsed onto the same
# wrong PMID because "Placebo"/"Carboplatin"/"Cisplatin" etc. are so common
# that the top hit was effectively just "most recent NSCLC trial paper").
GENERIC_DRUG_TERMS <- c(
  "placebo", "carboplatin", "cisplatin", "paclitaxel", "docetaxel",
  "gemcitabine", "pemetrexed", "vinorelbine", "etoposide", "nab-paclitaxel",
  "albumin-bound paclitaxel", "oxaliplatin", "irinotecan"
)

#' Fuzzy PubMed search: distinctive (non-backbone) drug name(s) OR'd together,
#' AND NSCLC, restricted to clinical trial publication types. Rejects the hit
#' if the query is still too broad to trust a single top result (large
#' result count means the drug terms weren't specific enough to this trial).
search_pubmed_fuzzy <- function(drug_names, retries = 1L, count_threshold = 15L) {
  if (is.na(drug_names) || !nzchar(drug_names)) return(NULL)
  drugs <- strsplit(drug_names, "; ")[[1]]
  drugs <- drugs[!tolower(drugs) %in% GENERIC_DRUG_TERMS]
  if (length(drugs) == 0) return(NULL)

  drug_term <- paste(sprintf("%s[tiab]", drugs), collapse = " OR ")
  term <- sprintf(
    '(%s) AND "non-small cell lung cancer"[tiab] AND (clinical trial[pt] OR clinical trial[tiab])',
    drug_term
  )
  result <- tryCatch(
    entrez_search(db = "pubmed", term = term, retmax = 3, sort = "relevance"),
    error = function(e) e
  )
  if (inherits(result, "error")) {
    if (retries > 0) { Sys.sleep(1); return(search_pubmed_fuzzy(drug_names, retries - 1L)) }
    return(NULL)
  }
  if (length(result$ids) == 0) return(NULL)
  if (result$count > count_threshold) return(NULL)

  top_pmid <- result$ids[1]
  summ <- tryCatch(entrez_summary(db = "pubmed", id = top_pmid), error = function(e) NULL)
  title <- if (!is.null(summ)) summ$title %||% NA_character_ else NA_character_
  list(pmid = top_pmid, title = title, n_results = result$count)
}

## ---- Stage 4/5: OpenAlex full-text NCT search and topic search --------

openalex_search <- function(filter_str = NULL, search_str = NULL, retries = 1L) {
  query <- list(`per-page` = 3)
  if (!is.null(filter_str)) query$filter <- filter_str
  if (!is.null(search_str)) query$search <- search_str

  resp <- tryCatch(
    GET("https://api.openalex.org/works", query = query),
    error = function(e) e
  )
  if (inherits(resp, "error") || http_error(resp)) {
    if (retries > 0) { Sys.sleep(1); return(openalex_search(filter_str, search_str, retries - 1L)) }
    return(NULL)
  }
  parsed <- fromJSON(content(resp, "text", encoding = "UTF-8"), simplifyVector = FALSE)
  if (length(parsed$results) == 0) return(NULL)

  top <- parsed$results[[1]]
  list(
    title = top$title %||% NA_character_,
    doi = top$doi %||% NA_character_,
    pmid = sub("^https://pubmed.ncbi.nlm.nih.gov/", "", top$ids$pmid %||% NA_character_),
    score = top$relevance_score %||% NA_real_
  )
}

search_openalex_fulltext <- function(nct_id) {
  openalex_search(filter_str = sprintf("fulltext.search:%s", nct_id))
}

search_openalex_topic <- function(drug_names, brief_title) {
  if (is.na(drug_names) || !nzchar(drug_names)) return(NULL)
  drugs <- strsplit(drug_names, "; ")[[1]]
  query_str <- paste(paste(drugs, collapse = " "), "non-small cell lung cancer")
  openalex_search(search_str = query_str)
}

## ---- Driver: run the cascade for one NCT ID ----------------------------

link_one_trial <- function(nct_id, ctgov_ref_pmids, ctgov_ref_citation, drug_names, brief_title) {
  # 1. CT.gov linked reference
  if (!is.na(ctgov_ref_pmids)) {
    return(tibble(
      nct_id = nct_id, match_source = "ctgov_reference", confidence = "high",
      pmid = ctgov_ref_pmids, doi = NA_character_, title_or_citation = ctgov_ref_citation,
      match_score = NA_real_
    ))
  }

  # 2. PubMed exact [si]
  si_ids <- search_pubmed_si(nct_id)
  Sys.sleep(PUBMED_DELAY)
  if (length(si_ids) > 0) {
    return(tibble(
      nct_id = nct_id, match_source = "pubmed_si", confidence = "high",
      pmid = paste(si_ids, collapse = ";"), doi = NA_character_,
      title_or_citation = NA_character_, match_score = NA_real_
    ))
  }

  # 3. PubMed fuzzy (drug + NSCLC)
  fuzzy <- search_pubmed_fuzzy(drug_names)
  Sys.sleep(PUBMED_DELAY)
  if (!is.null(fuzzy)) {
    return(tibble(
      nct_id = nct_id, match_source = "pubmed_fuzzy", confidence = "low",
      pmid = fuzzy$pmid, doi = NA_character_, title_or_citation = fuzzy$title,
      match_score = fuzzy$n_results
    ))
  }

  # 4. OpenAlex full-text NCT search
  oa_ft <- search_openalex_fulltext(nct_id)
  Sys.sleep(OPENALEX_DELAY)
  if (!is.null(oa_ft)) {
    return(tibble(
      nct_id = nct_id, match_source = "openalex_fulltext", confidence = "low",
      pmid = oa_ft$pmid, doi = oa_ft$doi, title_or_citation = oa_ft$title,
      match_score = oa_ft$score
    ))
  }

  # 5. OpenAlex topic search (drug + condition) -- last resort
  oa_topic <- search_openalex_topic(drug_names, brief_title)
  Sys.sleep(OPENALEX_DELAY)
  if (!is.null(oa_topic)) {
    return(tibble(
      nct_id = nct_id, match_source = "openalex_topic", confidence = "low",
      pmid = oa_topic$pmid, doi = oa_topic$doi, title_or_citation = oa_topic$title,
      match_score = oa_topic$score
    ))
  }

  tibble(
    nct_id = nct_id, match_source = "none", confidence = "unresolved",
    pmid = NA_character_, doi = NA_character_, title_or_citation = NA_character_,
    match_score = NA_real_
  )
}

## ---- Run ----------------------------------------------------------------

message("Reading candidate trials from Step 1...")
studies_df <- read.csv(STUDIES_IN, stringsAsFactors = FALSE)
nct_ids <- unique(studies_df$nct_id[!is.na(studies_df$nct_id)])
n_total <- length(nct_ids)

message(sprintf("Stage 1: batch-fetching CT.gov context (references, drug names) for %d NCT IDs...", n_total))
ctgov_raw <- fetch_ctgov_context(nct_ids)
ctgov_context <- map_dfr(ctgov_raw, extract_context_row)

message(sprintf("Stages 2-5: running PubMed/OpenAlex cascade for unresolved NCT IDs (%d total)...", n_total))

links_list <- vector("list", n_total)
for (i in seq_len(n_total)) {
  ctx <- ctgov_context[ctgov_context$nct_id == nct_ids[i], ]
  links_list[[i]] <- link_one_trial(
    nct_id = nct_ids[i],
    ctgov_ref_pmids = ctx$ctgov_ref_pmids[1],
    ctgov_ref_citation = ctx$ctgov_ref_citation[1],
    drug_names = ctx$drug_names[1],
    brief_title = ctx$brief_title[1]
  )

  if (i %% CHECKPOINT_EVERY == 0 || i == n_total) {
    message(sprintf("  ...%d / %d NCT IDs linked", i, n_total))
    bind_rows(links_list[seq_len(i)]) %>% write.csv(LINKS_OUT, row.names = FALSE)
  }
}

links_df <- bind_rows(links_list)

summary_tbl <- links_df %>% count(match_source, confidence, sort = TRUE)
n_high <- sum(links_df$confidence == "high")
n_low <- sum(links_df$confidence == "low")
n_unresolved <- sum(links_df$confidence == "unresolved")

message("\n--- Publication linkage summary ---")
print(summary_tbl, n = Inf)
message(sprintf("\nHigh confidence (CT.gov ref / PubMed exact):  %d (%.1f%%)", n_high, 100 * n_high / n_total))
message(sprintf("Low confidence (needs manual verification):    %d (%.1f%%)", n_low, 100 * n_low / n_total))
message(sprintf("Unresolved (no candidate found):               %d (%.1f%%)", n_unresolved, 100 * n_unresolved / n_total))
message(sprintf("\nWrote linkage table to %s", LINKS_OUT))
message("Note: 'low' confidence rows are single best-guess candidates, not")
message("confirmed links -- verify against full text before treating as the")
message("trial's primary publication (Step 3 territory, not this script).")
