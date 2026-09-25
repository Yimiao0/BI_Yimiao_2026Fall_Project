# Step 2, Stages 1-2 (nsclc_data_collection_workflow.md).
#
# Stage 1: classify each linked DOI as open access / free access / paywalled
# using Europe PMC's record for that DOI (isOpenAccess flag and the
# availability codes of its full-text links).
# Stage 2: screen the full text for Kaplan-Meier, PFS, and ORR mentions.
# Full text comes from Europe PMC's XML for open-access papers, or from the
# PubMed Central article page for free papers that have a PMCID. Journal sites
# block scripted downloads, so papers whose only free copy is there are left
# unscreened (NA).
#
# Input:  data/raw/step1_nct_publication_links.csv (from 01b_link_nct_to_pubmed.R)
# Output: data/raw/step2_nct_publication_links_with_doi.csv -- the trials with a
#         DOI, plus access_type and ORR_available / PFS_available /
#         KM_available (1 = mentioned, 0 = not, NA = full text not retrieved)

required_pkgs <- c("httr", "jsonlite", "dplyr", "purrr", "tibble")
missing_pkgs <- setdiff(required_pkgs, rownames(installed.packages()))
if (length(missing_pkgs) > 0) install.packages(missing_pkgs)

library(httr)
library(jsonlite)
library(dplyr)
library(purrr)
library(tibble)

LINKS_IN <- "data/raw/step1_nct_publication_links.csv"
LINKS_WITH_DOI_OUT <- "data/raw/step2_nct_publication_links_with_doi.csv"
EUROPEPMC_BASE <- "https://www.ebi.ac.uk/europepmc/webservices/rest"
EUROPEPMC_DELAY <- 0.15
PMC_BASE <- "https://pmc.ncbi.nlm.nih.gov/articles"
PMC_DELAY <- 0.35
# PMC pages shorter than this (as plain text) are treated as missing the
# article body, e.g. scanned articles shown only as page images.
MIN_FULLTEXT_CHARS <- 15000L
CHECKPOINT_EVERY <- 100L

`%||%` <- function(x, y) if (is.null(x)) y else x

## ---- Stage 1: access classification -------------------------------------

#' Look up a DOI in Europe PMC and classify its access:
#'   open_access      -- in Europe PMC's open-access subset (full text retrievable)
#'   free_access      -- free to read somewhere (publisher, author manuscript),
#'                       but not open-access licensed
#'   paywalled        -- only subscription-required full-text links
#'   not_in_europepmc -- no Europe PMC record for this DOI
#'   lookup_failed    -- the request errored
classify_access <- function(doi) {
  res <- tryCatch({
    resp <- GET(
      file.path(EUROPEPMC_BASE, "search"),
      query = list(query = sprintf('DOI:"%s"', doi), resultType = "core", format = "json")
    )
    stop_for_status(resp)
    fromJSON(content(resp, "text", encoding = "UTF-8"), simplifyVector = FALSE)$resultList$result
  }, error = function(e) e)

  if (inherits(res, "error")) {
    return(tibble(access_status = "lookup_failed", pmcid = NA_character_, free_fulltext_url = NA_character_))
  }
  if (length(res) == 0) {
    return(tibble(access_status = "not_in_europepmc", pmcid = NA_character_, free_fulltext_url = NA_character_))
  }

  rec <- res[[1]]
  urls <- rec$fullTextUrlList$fullTextUrl %||% list()
  codes <- map_chr(urls, function(u) u$availabilityCode %||% NA_character_)
  free_urls <- map_chr(urls[codes %in% c("OA", "F")], function(u) u$url %||% NA_character_)

  status <- if (identical(rec$isOpenAccess, "Y")) {
    "open_access"
  } else if (length(free_urls) > 0 || identical(rec$inEPMC, "Y")) {
    "free_access"
  } else {
    "paywalled"
  }

  tibble(
    access_status = status,
    pmcid = rec$pmcid %||% NA_character_,
    free_fulltext_url = if (length(free_urls) > 0) free_urls[1] else NA_character_
  )
}

ACCESS_TYPE_DESCRIPTIONS <- c(
  open_access = "Open license; full text downloaded from Europe PMC and searched",
  free_access = "Free to read (journal site, author manuscript, or repository) but no open license; searched only if a PubMed Central copy exists",
  paywalled = "Subscription required; not searched",
  not_in_europepmc = "No Europe PMC record for this DOI; not searched",
  lookup_failed = "Europe PMC request failed (e.g. network error); re-run to retry"
)

## ---- Stage 2: full-text keyword screen ----------------------------------

# Dash variants cover "Kaplan-Meier" / "Kaplan–Meier" / "Kaplan Meier".
KM_PATTERN <- "Kaplan[\\s\\-\\x{2010}-\\x{2015}]*Meier|\\bK-M\\b"
PFS_PATTERN <- "progression[\\s\\-\\x{2010}-\\x{2015}]*free survival|\\bPFS\\b"
# "response rate" also covers site-specific or pathologic response rates, so a
# 1 here means a response rate is reported, not necessarily a whole-body ORR.
ORR_PATTERN <- "objective response|response rate|\\bORR\\b"

#' Fetch the full-text XML for a PMCID from Europe PMC (open-access subset
#' only) and return it as plain text, or NA if unavailable.
fetch_fulltext <- function(pmcid) {
  if (is.na(pmcid)) return(NA_character_)
  tryCatch({
    resp <- GET(file.path(EUROPEPMC_BASE, pmcid, "fullTextXML"))
    if (status_code(resp) != 200) return(NA_character_)
    xml <- content(resp, "text", encoding = "UTF-8")
    gsub("\\s+", " ", gsub("<[^>]+>", " ", xml))
  }, error = function(e) NA_character_)
}

#' Fetch a PubMed Central article page and return it as plain text, or NA
#' if unavailable or too short to contain the article body. Used for free
#' papers outside the open-access subset (e.g. author manuscripts).
fetch_pmc_page <- function(pmcid) {
  if (is.na(pmcid)) return(NA_character_)
  tryCatch({
    resp <- GET(file.path(PMC_BASE, pmcid, ""), user_agent("Mozilla/5.0"))
    if (status_code(resp) != 200) return(NA_character_)
    html <- content(resp, "text", encoding = "UTF-8")
    html <- gsub("(?s)<(script|style)[^>]*>.*?</\\1>", " ", html, perl = TRUE, ignore.case = TRUE)
    text <- gsub("\\s+", " ", gsub("<[^>]+>", " ", html))
    if (nchar(text) < MIN_FULLTEXT_CHARS) NA_character_ else text
  }, error = function(e) NA_character_)
}

#' Screen one paper's full text for KM / PFS / ORR mentions: 1 if mentioned,
#' 0 if not, NA if the full text couldn't be retrieved.
screen_fulltext <- function(text) {
  if (is.na(text)) {
    return(tibble(ORR_available = NA_integer_, PFS_available = NA_integer_, KM_available = NA_integer_))
  }
  tibble(
    ORR_available = as.integer(grepl(ORR_PATTERN, text, perl = TRUE, ignore.case = TRUE)),
    PFS_available = as.integer(grepl(PFS_PATTERN, text, perl = TRUE, ignore.case = TRUE)),
    KM_available = as.integer(grepl(KM_PATTERN, text, perl = TRUE, ignore.case = TRUE))
  )
}

## ---- Run ----------------------------------------------------------------

links_df <- read.csv(LINKS_IN, stringsAsFactors = FALSE)
with_doi <- links_df %>%
  filter(!is.na(doi) & nzchar(doi)) %>%
  select(nct_id, match_source, ref_type, pmid, doi, title_or_citation)
n_total <- nrow(with_doi)
message(sprintf("Classifying and screening %d DOIs via Europe PMC...", n_total))

rows <- vector("list", n_total)
for (i in seq_len(n_total)) {
  access <- classify_access(with_doi$doi[i])
  Sys.sleep(EUROPEPMC_DELAY)

  text <- NA_character_
  if (access$access_status == "open_access") {
    text <- fetch_fulltext(access$pmcid)
    Sys.sleep(EUROPEPMC_DELAY)
  } else if (access$access_status == "free_access" && !is.na(access$pmcid)) {
    text <- fetch_pmc_page(access$pmcid)
    Sys.sleep(PMC_DELAY)
  }

  rows[[i]] <- bind_cols(
    with_doi[i, ],
    tibble(
      access_type = access$access_status,
      access_type_description = unname(ACCESS_TYPE_DESCRIPTIONS[access$access_status])
    ),
    screen_fulltext(text)
  )

  if (i %% CHECKPOINT_EVERY == 0 || i == n_total) {
    message(sprintf("  ...%d / %d DOIs done", i, n_total))
    bind_rows(rows[seq_len(i)]) %>% write.csv(LINKS_WITH_DOI_OUT, row.names = FALSE)
  }
}

screen_df <- bind_rows(rows)

message("\n--- Stage 1: access type ---")
print(count(screen_df, access_type, sort = TRUE))
message("\n--- Stage 2: KM/PFS/ORR screen (NA = full text not retrieved) ---")
print(count(screen_df, access_type, ORR_available, PFS_available, KM_available))
message(sprintf("\nWrote %s", LINKS_WITH_DOI_OUT))
