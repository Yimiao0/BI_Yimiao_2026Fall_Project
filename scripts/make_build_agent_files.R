# Write the data files in build_agent/version1/ (the files for building the DOI -> dataset
# AI agent) from the Step 2 and Step 3 outputs. The .md instruction files in
# build_agent/version1/ are written by hand; this script only makes the data files.
#
# Input:  data/raw/step2_nct_publication_links_with_doi.csv
#         data/raw/step3_stratum_arm_variables.xlsx
# Output: build_agent/version1/input_dois.csv            12 toy trials for the agent to read
#         build_agent/version1/input_dois.xlsx           same list as Excel, for tools that can't upload CSV
#         build_agent/version1/output_template.xlsx      empty sheets the agent fills, plus
#                                               the codebook of the columns it fills
#         build_agent/version1/testing/expected_decisions.csv
#                                               reviewed include / exclude
#                                               decisions, to test the agent

suppressMessages({
  library(dplyr)
  library(readxl)
  library(openxlsx)
})

LINKS_IN <- "data/raw/step2_nct_publication_links_with_doi.csv"
STEP3_IN <- "data/raw/step3_stratum_arm_variables.xlsx"
OUT_DIR <- "build_agent/version1"
dir.create(file.path(OUT_DIR, "testing"), recursive = TRUE, showWarnings = FALSE)

## ---- Input DOIs: a 12-trial toy set from the trials that passed Step 2 --------
# Open/free full text that passed the keyword screen, cut to 12 trials that
# cover every kind of decision: 5 included only, 2 with some arms excluded
# (NOT_NSCLC, OVERLAP) and 5 excluded as whole papers (SURGICAL,
# DEFINITIVE_CRT, ON_TREATMENT_SUBGROUP, PROTOCOL_ONLY, NO_ARM_LEVEL_RESULTS).

TOY_NCT_IDS <- c(
  "NCT03037385", "NCT00799240", "NCT00606021", "NCT04471428", "NCT00085501",  # included
  "NCT03473925", "NCT01038661",                                               # some arms excluded
  "NCT04205552", "NCT00563784", "NCT01774721", "NCT03689855", "NCT02367781"   # paper excluded
)
links <- read.csv(LINKS_IN, stringsAsFactors = FALSE)
input_dois <- links %>%
  filter(access_type %in% c("open_access", "free_access"),
         ORR_available == 1, PFS_available == 1, KM_available == 1,
         nct_id %in% TOY_NCT_IDS) %>%
  select(nct_id, pmid, doi, access_type, citation = title_or_citation)
stopifnot(nrow(input_dois) == length(TOY_NCT_IDS))
write.csv(input_dois, file.path(OUT_DIR, "input_dois.csv"), row.names = FALSE, na = "")
write.xlsx(input_dois, file.path(OUT_DIR, "input_dois.xlsx"), sheetName = "input_dois",
           headerStyle = createStyle(textDecoration = "bold"), firstRow = TRUE)

## ---- Codebook: only the columns the agent fills ------------------------------
# claude_collected also has columns derived later by tabulate_MOA_TrtStatus.R;
# the agent doesn't fill those, so the column list comes from claude_pilot.

agent_cols <- names(read_excel(STEP3_IN, sheet = "claude_pilot"))
cb_raw <- read_excel(STEP3_IN, sheet = "codebook", col_names = c("column", "description"))
codebook <- cb_raw %>%
  filter(column %in% agent_cols) %>%
  mutate(type = case_when(
    column %in% c("arm_id", "arm_sample_size", "female_count", "ajcc_edition") |
      grepl("^(ECOG|Tobacco|stage|squamous|nonsquamous|histology)_?", column) ~ "integer count",
    column %in% c("ORR", "ORR_ci_low", "ORR_ci_high") ~ "proportion 0-1",
    column %in% c("median_age", "mPFS_months", "mPFS_ci_low", "mPFS_ci_high") ~ "number",
    TRUE ~ "text"
  ))
codebook$type[codebook$column == "ajcc_edition"] <- "integer (6, 7 or 8)"
codebook$description[codebook$column == "arm_id"] <-
  "Unique ID for one arm within one stratum: one more than the largest arm_id already in included_arms (1 if empty)"
codebook$description[codebook$column == "notes"] <-
  "Source table/figure for the values, population used, and anything unusual (see agent_instructions.md, notes section)"
codebook <- codebook[match(agent_cols, codebook$column), c("column", "type", "description")]
codebook <- cbind(sheet = "included_arms", codebook)

# Columns of the excluded and failed_papers sheets.
codebook_other <- tribble(
  ~sheet, ~column, ~type, ~description,
  "excluded", "nct_id", "text", "ClinicalTrials.gov ID, from the input DOI list (input_dois)",
  "excluded", "doi", "text", "Publication DOI, from the input DOI list (input_dois)",
  "excluded", "exclusion_level", "text",
    "paper = the whole paper is out of scope (one row, arm_label and stratum blank); arm = one stratum-arm of a paper whose other arms are kept",
  "excluded", "arm_label", "text", "Short arm name, as it would appear in included_arms; blank for a paper-level row",
  "excluded", "stratum", "text", "Subgroup the row describes ('all' when not stratified); blank for a paper-level row",
  "excluded", "exclusion_code", "text", paste(
    "Why the paper or arm is out of scope (full rules in exclusion_rules.md).",
    "Paper type (paper-level only): TRIAL_MISMATCH = paper reports a different trial than nct_id;",
    "PROTOCOL_ONLY = study protocol with no results;",
    "NO_ARM_LEVEL_RESULTS = no arm-level baseline, ORR or PFS (pooled, biomarker-only, modelling papers, etc.).",
    "Out of scope: NOT_NSCLC = patients not mostly NSCLC;",
    "SURGICAL = surgery is part of the planned treatment (neoadjuvant, perioperative, surgery alone);",
    "DEFINITIVE_CRT = curative-intent chest radiation given with chemotherapy;",
    "INTRACRANIAL_ORR = ORR counts brain lesions only;",
    "ON_TREATMENT_SUBGROUP = strata defined by an event during treatment (e.g. side effects);",
    "OVERLAP = patients already counted in another included arm"),
  "excluded", "exclusion_evidence", "text", paste(
    "Short quote or paraphrase from the paper showing why, with its location",
    "(e.g. \"Methods: 'patients underwent surgery after 2 cycles of neoadjuvant therapy'\").",
    "For a wrong paper type, say what kind of paper it is and what is missing"),
  "failed_papers", "nct_id", "text", "ClinicalTrials.gov ID",
  "failed_papers", "doi", "text", "Publication DOI",
  "failed_papers", "reason", "text",
    "The agent couldn't get or read the paper: what it tried and what went wrong (no full text, page blocked, tables unreadable)"
)
codebook <- bind_rows(codebook, codebook_other)

## ---- Output template -----------------------------------------------------------

empty <- function(cols) as.data.frame(setNames(replicate(length(cols), character(0), simplify = FALSE), cols))
wb <- createWorkbook()
add_sheet <- function(wb, name, df) {
  addWorksheet(wb, name)
  writeData(wb, name, df, headerStyle = createStyle(textDecoration = "bold"))
  freezePane(wb, name, firstRow = TRUE)
}
add_sheet(wb, "included_arms", empty(agent_cols))
# Excluded rows are a short record, not a filled arm; a whole paper can be one row.
EXCLUDED_COLS <- c("nct_id", "doi", "exclusion_level", "arm_label", "stratum",
                   "exclusion_code", "exclusion_evidence")
add_sheet(wb, "excluded", empty(EXCLUDED_COLS))
add_sheet(wb, "failed_papers", empty(c("nct_id", "doi", "reason")))
add_sheet(wb, "codebook", codebook)
saveWorkbook(wb, file.path(OUT_DIR, "output_template.xlsx"), overwrite = TRUE)

## ---- Reviewed decisions, mapped to the agent's codes -------------------------

collected <- read_excel(STEP3_IN, sheet = "claude_collected")
irrelevant <- read_excel(STEP3_IN, sheet = "irrelevant_arms")
failed <- read_excel(STEP3_IN, sheet = "failed_open_free_papers")

exclusion_code <- function(reason) case_when(
  grepl("^not NSCLC", reason) ~ "NOT_NSCLC",
  grepl("^surgical", reason) ~ "SURGICAL",
  grepl("^definitive chemoradiation", reason) ~ "DEFINITIVE_CRT",
  grepl("^intracranial", reason) ~ "INTRACRANIAL_ORR",
  grepl("^overlapping", reason) ~ "OVERLAP",
  grepl("^post-treatment", reason) ~ "ON_TREATMENT_SUBGROUP"
)
# The old failed sheet holds papers of the wrong type, which the agent now
# excludes at paper level with a paper-type code.
paper_type_code <- function(reason) case_when(
  grepl("study protocol", reason, ignore.case = TRUE) ~ "PROTOCOL_ONLY",
  grepl("does not reference|mismatch", reason, ignore.case = TRUE) ~ "TRIAL_MISMATCH",
  TRUE ~ "NO_ARM_LEVEL_RESULTS"
)
irrelevant$exclusion_code <- exclusion_code(irrelevant$exclusion_reason)
stopifnot(!anyNA(irrelevant$exclusion_code))

# Papers that report a different trial than their nct_id are TRIAL_MISMATCH
# under the agent's rules, whatever their population.
mismatch <- irrelevant %>% filter(grepl("TRIAL MISMATCH", notes)) %>%
  distinct(nct_id, doi) %>%
  mutate(reason = "Trial mismatch: paper registers itself under a different NCT number")
irrelevant <- irrelevant %>% filter(!doi %in% mismatch$doi)
wrong_type <- bind_rows(failed, mismatch) %>%
  transmute(nct_id, doi, exclusion_level = "paper", arm_label = NA_character_, stratum = NA_character_,
            exclusion_code = paper_type_code(reason))

# A paper with no kept arm is a paper-level exclusion: one row, using the code
# that comes first in exclusion_rules.md.
CODE_ORDER <- c("TRIAL_MISMATCH", "PROTOCOL_ONLY", "NO_ARM_LEVEL_RESULTS", "NOT_NSCLC", "SURGICAL", "DEFINITIVE_CRT", "INTRACRANIAL_ORR",
                "ON_TREATMENT_SUBGROUP", "OVERLAP")
irrelevant$exclusion_level <- ifelse(irrelevant$doi %in% collected$doi, "arm", "paper")
excluded_rows <- bind_rows(
  irrelevant %>% filter(exclusion_level == "arm") %>%
    transmute(nct_id, doi, exclusion_level, arm_label, stratum, exclusion_code),
  irrelevant %>% filter(exclusion_level == "paper") %>%
    arrange(nct_id, match(exclusion_code, CODE_ORDER)) %>%
    group_by(nct_id, doi) %>%
    summarise(exclusion_level = "paper", arm_label = NA_character_, stratum = NA_character_,
              exclusion_code = first(exclusion_code), .groups = "drop"),
  wrong_type
) %>% arrange(nct_id)

## ---- Test set: what review decided for every arm and paper ---------------------

expected <- bind_rows(
  collected %>% transmute(nct_id, doi, level = "arm", arm_label, stratum, expected = "include", code = NA_character_),
  excluded_rows %>% transmute(nct_id, doi, level = exclusion_level, arm_label, stratum, expected = "exclude", code = exclusion_code)
) %>% arrange(nct_id)
write.csv(expected, file.path(OUT_DIR, "testing", "expected_decisions.csv"), row.names = FALSE, na = "")

is_exc <- expected$expected == "exclude"
message(sprintf(paste("input_dois: %d trials | codebook: %d columns | test set: %d arms included,",
                      "%d papers + %d arms excluded"),
                nrow(input_dois), sum(codebook$sheet == "included_arms"), sum(expected$expected == "include"),
                sum(is_exc & expected$level == "paper"), sum(is_exc & expected$level == "arm")))
