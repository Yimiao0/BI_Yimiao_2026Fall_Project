# Step 3, final stage (nsclc_data_collection_workflow.md).
#
# Move stratum-arms outside the analysis population out of the claude_collected
# sheet into the irrelevant_arms sheet, so claude_collected holds only NSCLC
# arms given systemic therapy for advanced/metastatic disease. Six reasons:
#   - not NSCLC: "NOT NSCLC" anywhere in notes
#   - surgical: surgery is part of the planned treatment (neoadjuvant,
#     preoperative or perioperative therapy, or surgery alone)
#   - definitive chemoradiation: curative-intent chemoradiation for
#     unresectable (locally advanced) stage III disease
#   - intracranial-only ORR: brain-metastasis cohorts whose ORR counts only
#     brain lesions (and, for arm 64, radiotherapy is the main treatment)
#   - overlapping population: patients already counted in another included arm
#     (NCT01523587 mainland China subgroup of the full arms 86/87; NCT03850444
#     KEYNOTE-042 China study, overlapping the global KEYNOTE-042, NCT02220894;
#     NCT01038661 maintenance-phase arms 206/207, whose patients are a subset of
#     the first-line-phase arms of the same trial)
#   - post-treatment subgroup: arms split by an on-treatment event (NCT01774721,
#     grade >=2 skin AE), so ORR and PFS are conditioned on the outcome period
# Surgical and chemoradiation arms are curative-intent treatment of early or
# locally advanced disease: ORR mostly reflects local treatment of the primary
# tumour and PFS is far longer, so neither is comparable with advanced-disease
# arms. They are listed by arm_id after review, because a keyword search also
# matches unrelated text (e.g. "unresectable", "prior neoadjuvant allowed").
# Other sheets are left unchanged. Safe to re-run: arms already in
# irrelevant_arms are not added twice.
#
# Input/output: data/raw/step3_stratum_arm_variables.xlsx
#   claude_collected -- analysis stratum-arms only
#   irrelevant_arms  -- the removed stratum-arms: exclusion_reason + same columns

required_pkgs <- c("openxlsx", "readxl", "dplyr")
missing_pkgs <- setdiff(required_pkgs, rownames(installed.packages()))
if (length(missing_pkgs) > 0) install.packages(missing_pkgs)

library(openxlsx)
library(readxl)

WORKBOOK <- "data/raw/step3_stratum_arm_variables.xlsx"
SOURCE_SHEET <- "claude_collected"
TARGET_SHEET <- "irrelevant_arms"
NOT_NSCLC_PATTERN <- "NOT NSCLC"
SURGICAL_ARM_IDS <- c(21, 67, 68, 108, 109, 126, 133, 226, 227, 242, 243)
CHEMORADIATION_ARM_IDS <- c(11, 33, 97, 98, 173, 223, 224)
INTRACRANIAL_ARM_IDS <- c(64, 130, 183)
OVERLAP_ARM_IDS <- c(88, 89, 206, 207, 245, 246)
POST_TREATMENT_SUBGROUP_ARM_IDS <- c(95, 96)

lock_file <- file.path(dirname(WORKBOOK), paste0("~$", basename(WORKBOOK)))
if (file.exists(lock_file)) {
  stop("Workbook appears to be open in Excel (", lock_file, "). Close it and re-run.")
}

# Read values with readxl: openxlsx's reader returns "&" as "&amp;"
read_sheet <- function(sheet) as.data.frame(read_excel(WORKBOOK, sheet = sheet))

wb <- loadWorkbook(WORKBOOK)
collected <- read_sheet(SOURCE_SHEET)

exclusion_reason <- function(df) {
  ifelse(grepl(NOT_NSCLC_PATTERN, df$notes), "not NSCLC",
         ifelse(df$arm_id %in% SURGICAL_ARM_IDS,
                paste("surgical (neoadjuvant/preoperative/perioperative or surgery alone):",
                      "curative-intent treatment of early/locally advanced disease;",
                      "ORR and PFS not comparable with advanced-disease arms"),
         ifelse(df$arm_id %in% CHEMORADIATION_ARM_IDS,
                paste("definitive chemoradiation for unresectable stage III:",
                      "curative-intent treatment of locally advanced disease;",
                      "ORR mostly reflects radiation of the primary tumour and PFS is",
                      "far longer, so not comparable with advanced-disease arms"),
         ifelse(df$arm_id %in% INTRACRANIAL_ARM_IDS,
                paste("intracranial-only ORR (brain-metastasis population):",
                      "response counts only brain lesions, so not comparable with",
                      "systemic RECIST ORR; arm 64 is also a brain radiotherapy trial",
                      "with PFS from the end of radiotherapy"),
         ifelse(df$arm_id %in% OVERLAP_ARM_IDS,
                paste("overlapping population: patients already counted in another",
                      "included arm (mainland China subgroup of NCT01523587; KEYNOTE-042",
                      "China study overlapping global KEYNOTE-042, NCT02220894; NCT01038661",
                      "maintenance phase, a subset of the trial's first-line-phase patients)"),
         ifelse(df$arm_id %in% POST_TREATMENT_SUBGROUP_ARM_IDS,
                paste("post-treatment subgroup: arm split by grade >=2 skin-related AE,",
                      "an on-treatment event, so ORR and PFS are conditioned on outcome"),
                NA_character_))))))
}
with_reason <- function(df) cbind(exclusion_reason = exclusion_reason(df), df)

reason <- exclusion_reason(collected)
is_irrelevant <- !is.na(reason)
moved <- with_reason(collected[is_irrelevant, , drop = FALSE])
kept <- collected[!is_irrelevant, , drop = FALSE]

if (TARGET_SHEET %in% names(wb)) {
  existing <- read_sheet(TARGET_SHEET)
  # Recompute reasons for rows already moved, so wording stays consistent
  existing <- with_reason(existing[, setdiff(names(existing), "exclusion_reason"), drop = FALSE])
  # Rewrite in full, so a sheet that gained a column leaves no stale cells
  deleteData(wb, TARGET_SHEET, cols = seq_len(ncol(existing)),
             rows = seq_len(nrow(existing) + 1), gridExpand = TRUE)
  # bind_rows, not rbind: tolerates columns added to claude_collected later
  moved <- dplyr::bind_rows(existing, moved[!moved$arm_id %in% existing$arm_id, , drop = FALSE])
} else {
  addWorksheet(wb, TARGET_SHEET)
  # Place the new sheet right after claude_collected
  sheet_order <- seq_along(names(wb))
  new_pos <- match(SOURCE_SHEET, names(wb))
  worksheetOrder(wb) <- append(sheet_order[-length(sheet_order)], length(sheet_order), new_pos)
}

# Clear the old rows before rewriting, so no stale rows are left at the bottom
deleteData(wb, SOURCE_SHEET, cols = seq_len(ncol(collected)),
           rows = seq_len(nrow(collected) + 1), gridExpand = TRUE)
writeData(wb, SOURCE_SHEET, kept, keepNA = FALSE)
writeData(wb, TARGET_SHEET, moved[order(moved$arm_id), , drop = FALSE], keepNA = FALSE)

saveWorkbook(wb, WORKBOOK, overwrite = TRUE)

cat(sprintf("Moved %d stratum-arms from %d trials to %s; %d remain in %s.\n",
            sum(is_irrelevant), length(unique(collected$nct_id[is_irrelevant])),
            TARGET_SHEET, nrow(kept), SOURCE_SHEET))
if (any(is_irrelevant)) print(table(reason[is_irrelevant]))
