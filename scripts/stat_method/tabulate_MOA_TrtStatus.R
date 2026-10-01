# Tabulate mechanism of action (moa) and participant treatment status
# (participants_trt_status) across the stratum-arms in claude_collected.
#
# Each table has one row per distinct value, with the number of stratum-arms
# and trials that have it, sorted from most to least common. The MOA table
# also assigns a broad category (moa_category, used by EDA.R), taking the first
# that applies:
#   IO + chemo               anti-PD-1/PD-L1/CTLA-4 plus chemotherapy
#   IO without chemo         anti-PD-1/PD-L1/CTLA-4, alone or with a non-chemo agent
#   Targeted therapy         drugs against a driver pathway (EGFR, HER2, ALK, RET,
#                            MET, BRAF/MEK, FGFR, ...), with or without other drugs
#   Anti-angiogenic + chemo  VEGF antibody or VEGFR TKI plus chemotherapy
#   Chemo alone              one or more cytotoxic drugs only
#   Other agent + chemo      another (mostly novel) agent plus chemotherapy
#   Other                    everything else (supportive care, placebo, vaccines,
#                            cell therapy, mTOR/PI3K inhibitors, anti-angiogenic alone)
# and 0/1 component indicators (written into the workbook by
# add_derived_variables.R), one per drug class in the regimen:
#   moa_chemo              cytotoxic chemotherapy
#   moa_immune_checkpoint  anti-PD-1, anti-PD-L1, anti-CTLA-4 (incl. bispecifics)
#   moa_immune_other       other immune agents: IDO1, TIGIT, LAG-3, CXCR2, TGF-beta,
#                          IL-15, TLR9, beta-glucan, vaccines, adoptive cell therapy
#   moa_antiangio          VEGF antibody, VEGFR/multikinase TKI, vascular disrupting
#   moa_targeted           driver-targeted: EGFR, HER2/pan-HER, ALK, RET, MET,
#                          BRAF/MEK, FGFR, KRAS, ROS1
#   moa_other              any other anti-cancer agent (mTOR, PI3K, PARP, IGF-1R,
#                          PDGFR/KIT, COX-2, survivin, dUTPase, HDAC/DNMT, ...)
# All zeros = no active drug (best supportive care, placebo). Radiotherapy and
# surgery are not drugs and get no column.
# The treatment
# status table also assigns a line of therapy (used by EDA.R):
#   First-line     treatment-naive for advanced/metastatic disease
#   Second-line    exactly one prior line
#   Later lines    two or more prior lines (third-line or later)
#   Other/unclear  maintenance, mixed populations, definitive chemoradiation for
#                  locally advanced disease, and pretreated arms whose number of
#                  prior lines is not stated or spans categories ("second- or later")
# and a first-line indicator (first_line, written into the workbook by
# add_derived_variables.R):
#   1  First-line; maintenance after first-line induction; mixed populations
#      that are mostly (>50%) treatment-naive
#   0  all pretreated arms (second-line, later lines, lines unclear); mixed
#      populations that are not mostly treatment-naive
# and a maintenance indicator (maintenance, also written by
# add_derived_variables.R): 1 for maintenance after induction without
# progression (a subset of first_line = 1, whose ORR is measured after the
# induction response), else 0
#
# The biomarker table has one row per distinct (biomarker_selection, moa) pair,
# because whether a population is sensitive depends on the drug. It assigns
#   biomarker_group    the population the arm was selected on (from
#                      biomarker_selection alone), e.g. EGFR sensitizing,
#                      EGFR T790M, ALK, PD-L1 >=50%, Driver-negative, Unselected
#   biomarker_matched  1 if the population was selected on a validated predictive
#                      biomarker for a drug in the regimen, else 0:
#                        EGFR sensitizing mutation   + any EGFR TKI
#                        EGFR T790M                  + 3rd-generation EGFR TKI
#                        EGFR ex20ins/uncommon       + EGFR-MET bispecific
#                        ALK / RET / MET ex14 / BRAF V600E + the matching inhibitor
#                        PD-L1 >=1%, PD-L1 >=50%, TMB-high + PD-1/PD-L1/CTLA-4 antibody
#                      Target-directed but unvalidated selections (KRAS + MEK,
#                      HER2 + pan-HER TKI, PI3K/mTOR pathway, FGFR, EGFR IHC,
#                      pharmacodynamic or clinical enrichment) are 0.
#
# Input:  data/raw/step3_stratum_arm_variables.xlsx (sheet "claude_collected")
# Output: data/raw/moa_tabulation.csv
#         data/raw/trtstatus_tabulation.csv
#         data/raw/biomarker_tabulation.csv

required_pkgs <- c("readxl", "dplyr")
missing_pkgs <- setdiff(required_pkgs, rownames(installed.packages()))
if (length(missing_pkgs) > 0) install.packages(missing_pkgs)

library(readxl)
library(dplyr)

DATA_IN <- "data/raw/step3_stratum_arm_variables.xlsx"
SHEET <- "claude_collected"
MOA_OUT <- "data/raw/moa_tabulation.csv"
TRTSTATUS_OUT <- "data/raw/trtstatus_tabulation.csv"
BIOMARKER_OUT <- "data/raw/biomarker_tabulation.csv"

arm_df <- read_excel(DATA_IN, sheet = SHEET)

tabulate_column <- function(df, column) {
  df %>%
    group_by(value = .data[[column]]) %>%
    summarise(n_arms = n(), n_trials = n_distinct(nct_id), .groups = "drop") %>%
    mutate(pct_arms = round(100 * n_arms / nrow(df), 1)) %>%
    arrange(desc(n_arms), value) %>%
    rename(!!column := value)
}

classify_line <- function(status) {
  s <- tolower(status)
  other <- grepl("definitive chemoradiation|locally advanced|^mixed|first- or second-line|maintenance", s)
  first <- grepl("^treatment-naive|^no prior cytotoxic", s)
  later <- grepl(paste0("third|3rd|>=2 (prior|lines|regimens)|with >=2|median (2|2\\.5|3) prior|",
                        "1-6 prior|and >=1 line of chemo|and 1-2 (lines of )?chemo|55% >=3"), s)
  spans <- grepl("second- or|second/third|second-line\\+|1-2 prior|1-3 prior", s)
  second <- grepl(paste0("second-line|(^|[^=])1 prior|one line|progressed on first-line|",
                         "progressed after first-line|failed first-line"), s)
  ifelse(other, "Other/unclear",
  ifelse(first, "First-line",
  ifelse(later & !spans, "Later lines",
  ifelse(second & !spans, "Second-line", "Other/unclear"))))
}

# Mixed populations that are mostly treatment-naive, from the proportions in
# participants_trt_status or notes (checked by hand). All other mixed arms are
# mostly pretreated or exactly 50/50 ("10 first-line, 10 previously treated").
MIXED_MOSTLY_NAIVE <- c("mixed (70% treatment-naive; <2 prior chemotherapy regimens)")

classify_first_line <- function(status, line) {
  s <- tolower(status)
  as.integer(line == "First-line" | grepl("maintenance", s) | status %in% MIXED_MOSTLY_NAIVE)
}

classify_maintenance <- function(status) as.integer(grepl("maintenance", tolower(status)))

MOA_CATEGORIES <- c("Chemo alone", "Anti-angiogenic + chemo", "IO + chemo", "IO without chemo",
                    "Targeted therapy", "Other agent + chemo", "Other")

classify_moa <- function(moa) {
  m <- tolower(moa)
  chemo <- grepl(paste0("chemo|platinum|taxane|antifolate|fluoropyrimidine|alkylating|",
                        "epothilone|microtubule|topoisomerase"), m)
  io <- grepl("pd-1|pd-l1|ctla-4", m)
  angio <- grepl("vegf|multikinase|vascular|egfl7", m)
  # Anti-angiogenic multikinase TKIs that also list FGFR are not driver-targeted
  targeted <- grepl("\\begfr|\\balk\\b|\\bret\\b|\\bmet\\b|braf|\\bmek\\b|pan-her|erbb|her2|fgfr|kras|ros1", m) &
    !grepl("^multi-target vegfr", m)
  # Only cytotoxic drugs: no "+" partner, or the partner is itself chemotherapy
  chemo_only <- chemo & (!grepl("\\+|followed", m) | grepl("non-platinum doublet chemotherapy\\)$", m))
  ifelse(io & chemo, "IO + chemo",
  ifelse(io, "IO without chemo",
  ifelse(targeted, "Targeted therapy",
  ifelse(angio & chemo, "Anti-angiogenic + chemo",
  ifelse(chemo_only, "Chemo alone",
  ifelse(chemo, "Other agent + chemo", "Other"))))))
}

# Split a regimen into its agents ("A + B", "A followed by B"), dropping
# parenthetical qualifiers, and flag each drug class present
MOA_COMPONENTS <- c("moa_chemo", "moa_immune_checkpoint", "moa_immune_other",
                    "moa_antiangio", "moa_targeted", "moa_other")

classify_moa_components <- function(moa) {
  agents <- lapply(strsplit(gsub("\\([^)]*\\)", "", tolower(moa)), "\\+| followed by "), trimws)
  flag_agents <- function(a) {
    chemo <- grepl(paste0("chemo|platinum|taxane|antifolate|fluoropyrimidine|alkylating|",
                          "epothilone|microtubule|topoisomerase"), a)
    checkpoint <- grepl("pd-1|pd-l1|ctla-4", a)
    targeted <- grepl("\\begfr|\\balk\\b|\\bret\\b|\\bmet\\b|braf|\\bmek\\b|pan-her|erbb|her2|kras|ros1|pan-fgfr", a)
    antiangio <- grepl("vegf|multikinase|egfl7|vascular disrupting", a) & !targeted
    immune_other <- grepl("ido1|tigit|lag-3|cxcr2|tgf-beta|il-15|tlr9|beta-glucan|vaccine|adoptive", a) &
      !checkpoint
    no_drug <- grepl("best supportive|placebo|radiotherapy|surgery", a)
    other <- !(chemo | checkpoint | targeted | antiangio | immune_other | no_drug)
    as.integer(c(any(chemo), any(checkpoint), any(immune_other), any(antiangio),
                 any(targeted), any(other)))
  }
  out <- as.data.frame(do.call(rbind, lapply(agents, flag_agents)))
  names(out) <- MOA_COMPONENTS
  out
}

BIOMARKER_GROUPS <- c("EGFR sensitizing", "EGFR T790M", "EGFR TKI-resistant", "EGFR uncommon/ex20ins",
                      "ALK", "RET", "MET ex14", "BRAF V600E", "HER2", "KRAS", "Other alteration",
                      "PD-L1 >=50%", "PD-L1 >=1%", "TMB-high", "Driver-negative", "Unselected",
                      "Other/clinical")

# Population the arm was selected on, first rule that applies
classify_biomarker_group <- function(biomarker) {
  b <- tolower(biomarker)
  rules <- list(
    "EGFR TKI-resistant" = grepl("tki-resistant", b),
    "EGFR T790M" = grepl("t790m", b) & !grepl("t790m (mostly )?negative", b),
    "EGFR uncommon/ex20ins" = grepl("uncommon egfr|ex20ins", b),
    "EGFR sensitizing" = grepl("^egfr (mutation|sensitizing|exon 19)", b),
    "ALK" = grepl("^alk rearrangement", b),
    "RET" = grepl("^ret fusion", b),
    "MET ex14" = grepl("met exon 14", b),
    "BRAF V600E" = grepl("braf v600e", b),
    "HER2" = grepl("^her2", b),
    "KRAS" = grepl("^kras mutation", b),
    "TMB-high" = grepl("high tmb", b),
    "PD-L1 >=50%" = grepl("pd-l1 tps >=50%", b),
    "PD-L1 >=1%" = grepl("pd-l1 tps >=1%", b),
    "Other alteration" = grepl("fgfr alteration|pi3k pathway|stk11|tsc1|tp53", b),
    "Other/clinical" = grepl("kras wild-type or egfr", b),
    "Driver-negative" = grepl("negative|wild-type|not indicated|not positive|excluded egfr-mutant", b) &
      !grepl("egfr (mutant|mutation) in", b),
    "Unselected" = grepl("^(none|unselected)", b)
  )
  out <- rep("Other/clinical", length(b))
  for (g in rev(names(rules))) out[rules[[g]]] <- g  # earlier rules win
  out
}

classify_biomarker_matched <- function(group, moa) {
  m <- tolower(moa)
  egfr_tki <- grepl("egfr tki|egfr-met bispecific", m)
  egfr_3rd <- grepl("egfr tki \\(3rd generation\\)|egfr-met bispecific", m)
  checkpoint <- grepl("pd-1|pd-l1|ctla-4", m)
  as.integer(
    (group == "EGFR sensitizing" & egfr_tki) |
    (group == "EGFR T790M" & egfr_3rd) |
    (group == "EGFR uncommon/ex20ins" & grepl("egfr-met bispecific", m)) |
    (group == "ALK" & grepl("\\balk\\b", m, perl = TRUE)) |
    (group == "RET" & grepl("ret inhibitor", m)) |
    (group == "MET ex14" & grepl("^met inhibitor", m)) |
    (group == "BRAF V600E" & grepl("braf inhibitor", m)) |
    (group %in% c("PD-L1 >=50%", "PD-L1 >=1%", "TMB-high") & checkpoint)
  )
}

moa_tab <- tabulate_column(arm_df, "moa") %>%
  mutate(moa_category = classify_moa(moa), .after = 1)
moa_tab <- bind_cols(moa_tab[, 1:2], classify_moa_components(moa_tab$moa), moa_tab[, -(1:2)])
trtstatus_tab <- tabulate_column(arm_df, "participants_trt_status") %>%
  mutate(line_of_therapy = classify_line(participants_trt_status),
         first_line = classify_first_line(participants_trt_status, line_of_therapy),
         maintenance = classify_maintenance(participants_trt_status),
         .after = 1)

biomarker_tab <- arm_df %>%
  group_by(biomarker_selection, moa) %>%
  summarise(n_arms = n(), n_trials = n_distinct(nct_id), .groups = "drop") %>%
  mutate(biomarker_group = classify_biomarker_group(biomarker_selection),
         biomarker_matched = classify_biomarker_matched(biomarker_group, moa),
         .after = moa) %>%
  arrange(desc(biomarker_matched), factor(biomarker_group, levels = BIOMARKER_GROUPS),
          biomarker_selection, moa)

write.csv(moa_tab, MOA_OUT, row.names = FALSE)
write.csv(trtstatus_tab, TRTSTATUS_OUT, row.names = FALSE)
write.csv(biomarker_tab, BIOMARKER_OUT, row.names = FALSE)

cat(sprintf("Stratum-arms: %d\n", nrow(arm_df)))
cat(sprintf("moa: %d distinct values -> %s\n", nrow(moa_tab), MOA_OUT))
cat(sprintf("participants_trt_status: %d distinct values -> %s\n",
            nrow(trtstatus_tab), TRTSTATUS_OUT))
print(count(moa_tab, moa_category, wt = n_arms, name = "n_arms") %>% arrange(desc(n_arms)))
cat("Arms per MOA component:\n")
print(colSums(moa_tab[, MOA_COMPONENTS] * moa_tab$n_arms))
print(count(trtstatus_tab, line_of_therapy, first_line, maintenance, wt = n_arms, name = "n_arms"))
cat(sprintf("(biomarker_selection, moa): %d distinct pairs -> %s\n", nrow(biomarker_tab), BIOMARKER_OUT))
print(count(biomarker_tab, biomarker_group, biomarker_matched, wt = n_arms, name = "n_arms"))
