# Add derived variables to the claude_collected sheet and describe them in the
# codebook sheet:
#   first_line, maintenance
#                         0/1, placed after participants_trt_status
#   moa_chemo, moa_immune_checkpoint, moa_immune_other, moa_antiangio,
#   moa_targeted, moa_other
#                         0/1 MOA components, placed after moa
#   biomarker_group, biomarker_matched
#                         selected population and 0/1 validated-biomarker match,
#                         looked up by (biomarker_selection, moa), placed after
#                         biomarker_selection
# The values per treatment status / moa come from tabulate_MOA_TrtStatus.R
# (see its header for the rules); run that script first. Safe to re-run:
# existing derived columns and codebook rows are replaced. Other sheets are
# left unchanged.
#
# Input:  data/raw/trtstatus_tabulation.csv
#         data/raw/moa_tabulation.csv
#         data/raw/biomarker_tabulation.csv
# Input/output: data/raw/step3_stratum_arm_variables.xlsx
#   claude_collected -- gains the derived columns
#   codebook         -- gains one row per derived column

required_pkgs <- c("openxlsx", "readxl")
missing_pkgs <- setdiff(required_pkgs, rownames(installed.packages()))
if (length(missing_pkgs) > 0) install.packages(missing_pkgs)

library(openxlsx)
library(readxl)

WORKBOOK <- "data/raw/step3_stratum_arm_variables.xlsx"
DATA_SHEET <- "claude_collected"
CODEBOOK_SHEET <- "codebook"

# Each derived variable: source tabulation, the key column(s) it is looked up by
# (placed after the first key), and its codebook description
DERIVED <- list(
  list(file = "data/raw/trtstatus_tabulation.csv", key = "participants_trt_status",
       cols = c(first_line = paste(
         "First-line indicator derived from participants_trt_status (1 = first-line,",
         "including maintenance after first-line induction and mixed populations >50%",
         "treatment-naive; 0 = pretreated, or mixed populations not >50% treatment-naive)"),
         maintenance = paste(
           "Maintenance indicator derived from participants_trt_status (1 = maintenance after",
           "induction without progression, a subset of first_line = 1; 0 otherwise)"))),
  list(file = "data/raw/moa_tabulation.csv", key = "moa",
       cols = c(
         moa_chemo = "1 if the regimen includes cytotoxic chemotherapy",
         moa_immune_checkpoint = "1 if the regimen includes an immune checkpoint inhibitor (anti-PD-1, anti-PD-L1, anti-CTLA-4)",
         moa_immune_other = paste("1 if the regimen includes another immune agent (IDO1, TIGIT, LAG-3,",
                                  "CXCR2, TGF-beta, IL-15, TLR9, beta-glucan, vaccine, adoptive cell therapy)"),
         moa_antiangio = "1 if the regimen includes an anti-angiogenic agent (VEGF antibody, VEGFR/multikinase TKI)",
         moa_targeted = paste("1 if the regimen includes a driver-targeted agent (EGFR, HER2, ALK, RET,",
                              "MET, BRAF/MEK, FGFR, KRAS, ROS1)"),
         moa_other = paste("1 if the regimen includes any other anti-cancer agent (mTOR, PI3K, PARP,",
                           "IGF-1R, COX-2, survivin, HDAC, ...). All moa_* = 0: no active drug"))),
  list(file = "data/raw/biomarker_tabulation.csv", key = c("biomarker_selection", "moa"),
       cols = c(
         biomarker_group = paste(
           "Population the arm was selected on, grouped from biomarker_selection (EGFR sensitizing,",
           "EGFR T790M, EGFR TKI-resistant, EGFR uncommon/ex20ins, ALK, RET, MET ex14, BRAF V600E,",
           "HER2, KRAS, Other alteration, PD-L1 >=50%, PD-L1 >=1%, TMB-high, Driver-negative,",
           "Unselected, Other/clinical)"),
         biomarker_matched = paste(
           "1 if the population was selected on a validated predictive biomarker for a drug in the",
           "regimen (EGFR sensitizing + EGFR TKI; T790M + 3rd-generation EGFR TKI; ex20ins +",
           "EGFR-MET bispecific; ALK/RET/MET ex14/BRAF V600E + matching inhibitor; PD-L1 or",
           "TMB-high + checkpoint inhibitor), else 0")))
)
SOURCE_NOTE <- "Set by tabulate_MOA_TrtStatus.R"

lock_file <- file.path(dirname(WORKBOOK), paste0("~$", basename(WORKBOOK)))
if (file.exists(lock_file)) {
  stop("Workbook appears to be open in Excel (", lock_file, "). Close it and re-run.")
}

# Read values with readxl: openxlsx's reader returns "&" as "&amp;"
read_sheet <- function(sheet) as.data.frame(read_excel(WORKBOOK, sheet = sheet))

# Replace a sheet's contents in full, so no stale cells are left behind
rewrite_sheet <- function(wb, sheet, old, new) {
  deleteData(wb, sheet, cols = seq_len(max(ncol(old), ncol(new))),
             rows = seq_len(nrow(old) + 1), gridExpand = TRUE)
  writeData(wb, sheet, new, keepNA = FALSE)
}

# Put new_cols (already in df) directly after the column `after`
move_after <- function(df, new_cols, after) {
  rest <- setdiff(names(df), new_cols)
  df[, append(rest, new_cols, after = match(after, rest))]
}

wb <- loadWorkbook(WORKBOOK)
collected <- read_sheet(DATA_SHEET)
codebook <- read_sheet(CODEBOOK_SHEET)
all_derived <- unlist(lapply(DERIVED, function(d) names(d$cols)))

new_data <- collected[, setdiff(names(collected), all_derived), drop = FALSE]
new_codebook <- codebook[!codebook$column %in% all_derived, , drop = FALSE]

for (d in DERIVED) {
  map <- read.csv(d$file)
  key_of <- function(df) do.call(paste, c(df[d$key], sep = "\r"))
  idx <- match(key_of(new_data), key_of(map))
  if (anyNA(idx)) {
    stop("No derived values for ", paste(d$key, collapse = " + "), " of arm_id ",
         paste(new_data$arm_id[is.na(idx)], collapse = ", "),
         ". Re-run tabulate_MOA_TrtStatus.R first.")
  }
  for (col in names(d$cols)) new_data[[col]] <- map[[col]][idx]
  new_data <- move_after(new_data, names(d$cols), d$key[1])

  pos <- match(d$key[1], new_codebook$column)
  rows <- data.frame(column = names(d$cols), description = paste0(d$cols, ". ", SOURCE_NOTE))
  new_codebook <- rbind(new_codebook[seq_len(pos), , drop = FALSE], rows,
                        new_codebook[-seq_len(pos), , drop = FALSE])
}

rewrite_sheet(wb, DATA_SHEET, collected, new_data)
rewrite_sheet(wb, CODEBOOK_SHEET, codebook, new_codebook)
saveWorkbook(wb, WORKBOOK, overwrite = TRUE)

cat(sprintf("Added %s to %s (%d arms). Arms with value 1:\n",
            paste(all_derived, collapse = ", "), DATA_SHEET, nrow(new_data)))
numeric_derived <- all_derived[vapply(new_data[all_derived], is.numeric, logical(1))]
print(colSums(new_data[, numeric_derived]))
print(table(new_data$biomarker_group, new_data$biomarker_matched, dnn = c("biomarker_group", "matched")))
