# Figure 1 (nsclc_data_collection_workflow.md): PRISMA-style flow diagram of
# trial identification/filtering (Step 1) and publication linkage (Step 2).
#
# Fully reproducible from already-saved pipeline outputs -- no network calls.
# Re-derives the Step 1 attrition counts by re-applying the same filter
# constants used in 01_pull_ctgov_candidates.R directly to the saved raw pool
# (keep these two constants in sync with that script if it changes), and reads
# the match confidence breakdown straight from Step 2's output.
#
# Input:  data/raw/step1_ctgov_raw_all_completed_interventional.csv
#         data/raw/step2_nct_publication_links.csv
# Output: figures/figure1_trial_flow.png

required_pkgs <- c("dplyr", "ggplot2")
missing_pkgs <- setdiff(required_pkgs, rownames(installed.packages()))
if (length(missing_pkgs) > 0) install.packages(missing_pkgs)

library(dplyr)
library(ggplot2)

RAW_IN <- "data/raw/step1_ctgov_raw_all_completed_interventional.csv"
LINKS_IN <- "data/raw/step2_nct_publication_links.csv"
FIG_DIR <- "figures"
FIG_OUT <- file.path(FIG_DIR, "figure1_trial_flow.png")

dir.create(FIG_DIR, recursive = TRUE, showWarnings = FALSE)

# Must match 01_pull_ctgov_candidates.R's KEEP_IF_ANY_TYPE / KEEP_IF_PHASE.
KEEP_IF_ANY_TYPE <- c("DRUG", "BIOLOGICAL", "COMBINATION_PRODUCT")
KEEP_IF_PHASE <- c("PHASE1; PHASE2", "PHASE2", "PHASE2; PHASE3", "PHASE3")

## ---- Re-derive Step 1 attrition from the saved raw pool ----------------

is_drug_like <- function(intervention_types) {
  if (is.na(intervention_types)) return(FALSE)
  any(strsplit(intervention_types, "; ")[[1]] %in% KEEP_IF_ANY_TYPE)
}

raw_df <- read.csv(RAW_IN, stringsAsFactors = FALSE) %>%
  mutate(
    kept = vapply(intervention_types, is_drug_like, logical(1)) &
      primary_purpose %in% "TREATMENT" &
      phase %in% KEEP_IF_PHASE &
      !is.na(enrollment_count)
  )

n0 <- nrow(raw_df)
n_candidates <- sum(raw_df$kept)

message(sprintf("Step 1: identified %d -> candidates %d (-%d excluded)", n0, n_candidates, n0 - n_candidates))

## ---- Step 2 confidence breakdown from the saved linkage table ----------

links_df <- read.csv(LINKS_IN, stringsAsFactors = FALSE)
n_searched <- nrow(links_df)
n_high <- sum(links_df$confidence == "high")
n_low <- sum(links_df$confidence == "low")
n_unresolved <- sum(links_df$confidence == "unresolved")

message(sprintf("Step 2 outcome: searched %d -> high %d / low %d / unresolved %d",
                 n_searched, n_high, n_low, n_unresolved))

if (n_searched != n_candidates) {
  warning(sprintf(
    "Step 1 candidate count (%d) != Step 2 searched count (%d) -- Step 2 is stale, re-run 02_link_nct_to_pubmed.R",
    n_candidates, n_searched
  ))
}

## ---- Layout: main flow column + exclusion side-boxes -------------------

BOX_W <- 6; BOX_H <- 1.3; GAP <- 0.9
EXCL_X0 <- BOX_W + 1.2; EXCL_W <- 5.2; EXCL_H <- 1.5

main_boxes <- tibble(
  label = c(
    "Completed, interventional\nNSCLC trials",
    "Step 1 candidate trials",
    "Searched via CT.gov refs ->\nPubMed -> OpenAlex"
  ),
  n = c(n0, n_candidates, n_searched)
)
n_main <- nrow(main_boxes)
main_boxes$ymax <- rev(seq_len(n_main)) * (BOX_H + GAP)
main_boxes$ymin <- main_boxes$ymax - BOX_H
main_boxes$xmin <- 0
main_boxes$xmax <- BOX_W
main_boxes$ycenter <- (main_boxes$ymin + main_boxes$ymax) / 2

# All four criteria are applied together (not one exclusion box per
# criterion) -- matches 01_pull_ctgov_candidates.R's combined "kept" filter.
excl_boxes <- tibble(
  label = sprintf(
    "-%s excluded\n(fails any of: drug-like type,\npurpose = TREATMENT, phase in\n{1/2, 2, 2/3, 3}, enrollment reported)",
    format(n0 - n_candidates, big.mark = ",")
  ),
  gap_after_box = 1
)
excl_boxes$ymid <- (main_boxes$ymin[excl_boxes$gap_after_box] + main_boxes$ymax[excl_boxes$gap_after_box + 1]) / 2
excl_boxes$ymin <- excl_boxes$ymid - EXCL_H / 2
excl_boxes$ymax <- excl_boxes$ymid + EXCL_H / 2
excl_boxes$xmin <- EXCL_X0
excl_boxes$xmax <- EXCL_X0 + EXCL_W

## ---- Terminal fork: high / low / unresolved -----------------------------

term_y_top <- min(main_boxes$ymin) - GAP
TERM_H <- 2.15; TERM_GAP <- 0.3
term_w <- (BOX_W - 2 * TERM_GAP) / 3

pct <- function(x) sprintf("%.1f%%", 100 * x / n_searched)
term_boxes <- tibble(
  label = c("High confidence", "Low confidence", "Unresolved"),
  sublabel = c("CT.gov ref /\nPubMed exact", "PubMed fuzzy /\nOpenAlex", "no candidate\nfound"),
  n = c(n_high, n_low, n_unresolved),
  pct = c(pct(n_high), pct(n_low), pct(n_unresolved)),
  fill = c("#0ca30c", "#fab219", "#d03b3b"),
  text_col = c("white", "#2a1d00", "white")
)
term_boxes$xmin <- c(0, term_w + TERM_GAP, 2 * (term_w + TERM_GAP))
term_boxes$xmax <- term_boxes$xmin + term_w
term_boxes$ymax <- term_y_top
term_boxes$ymin <- term_y_top - TERM_H

## ---- Build the plot ------------------------------------------------------

ACCENT <- "#2a78d6"
EXCL_FILL <- "#2f3742"

p <- ggplot() +
  # main flow -> arrows
  geom_segment(
    data = main_boxes[-n_main, ],
    aes(x = BOX_W / 2, xend = BOX_W / 2, y = ymin, yend = ymin - GAP + 0.08),
    arrow = arrow(length = unit(0.12, "in"), type = "closed"), color = "grey35", linewidth = 0.6
  ) +
  geom_segment(
    aes(x = BOX_W / 2, xend = BOX_W / 2, y = min(main_boxes$ymin), yend = term_y_top + 0.08),
    arrow = arrow(length = unit(0.12, "in"), type = "closed"), color = "grey35", linewidth = 0.6
  ) +
  # connector taps to exclusion boxes
  geom_segment(
    data = excl_boxes,
    aes(x = BOX_W / 2, xend = xmin, y = ymid, yend = ymid),
    color = "grey55", linewidth = 0.5
  ) +
  # fork lines to terminal boxes
  geom_segment(
    aes(x = BOX_W / 2, xend = term_boxes$xmin + term_w / 2,
        y = min(main_boxes$ymin) - GAP * 0.55, yend = min(main_boxes$ymin) - GAP * 0.55),
    color = "grey55", linewidth = 0.5
  ) +
  geom_segment(
    aes(x = term_boxes$xmin + term_w / 2, xend = term_boxes$xmin + term_w / 2,
        y = min(main_boxes$ymin) - GAP * 0.55, yend = term_y_top + 0.05),
    arrow = arrow(length = unit(0.1, "in"), type = "closed"), color = "grey35", linewidth = 0.6
  ) +
  # main boxes
  geom_rect(data = main_boxes, aes(xmin = xmin, xmax = xmax, ymin = ymin, ymax = ymax),
            fill = ACCENT, color = NA) +
  geom_text(data = main_boxes, aes(x = BOX_W / 2, y = ycenter + 0.18, label = label),
            color = "white", size = 3.3, lineheight = 0.95) +
  geom_text(data = main_boxes, aes(x = BOX_W / 2, y = ycenter - 0.28, label = format(n, big.mark = ",")),
            color = "white", size = 4.2, fontface = "bold", family = "mono") +
  # exclusion boxes
  geom_rect(data = excl_boxes, aes(xmin = xmin, xmax = xmax, ymin = ymin, ymax = ymax),
            fill = EXCL_FILL, color = NA) +
  geom_text(data = excl_boxes, aes(x = (xmin + xmax) / 2, y = ymid, label = label),
            color = "white", size = 2.9, lineheight = 1.05) +
  # terminal boxes
  geom_rect(data = term_boxes, aes(xmin = xmin, xmax = xmax, ymin = ymin, ymax = ymax, fill = I(fill)),
            color = NA) +
  geom_text(data = term_boxes, aes(x = (xmin + xmax) / 2, y = ymax - 0.35, label = label, color = I(text_col)),
            size = 3.2, fontface = "bold") +
  geom_text(data = term_boxes, aes(x = (xmin + xmax) / 2, y = ymax - 0.75, label = paste0(format(n, big.mark = ","), " (", pct, ")"), color = I(text_col)),
            size = 3.0, family = "mono") +
  geom_text(data = term_boxes, aes(x = (xmin + xmax) / 2, y = ymax - 1.5, label = sublabel, color = I(text_col)),
            size = 2.3, lineheight = 0.95) +
  annotate("text", x = 0, y = max(main_boxes$ymax) + 0.55, label = "STEP 1 - TRIAL IDENTIFICATION & FILTERING",
           hjust = 0, size = 3.1, fontface = "bold", color = "grey40") +
  annotate("text", x = 0, y = term_y_top + GAP - 0.3, label = "STEP 2 - LITERATURE SEARCH FOR A LINKED PUBLICATION",
           hjust = 0, size = 3.1, fontface = "bold", color = "grey40") +
  coord_fixed(xlim = c(-0.3, EXCL_X0 + EXCL_W + 0.3), ylim = c(term_y_top - TERM_H - 0.3, max(main_boxes$ymax) + 0.9), clip = "off") +
  theme_void() +
  labs(title = "NSCLC trial identification, filtering, and publication linkage",
       subtitle = sprintf("ClinicalTrials.gov (n=%s) -> Step 1 candidates (n=%s) -> Step 2 linkage outcome", format(n0, big.mark=","), format(n_candidates, big.mark=","))) +
  theme(
    plot.title = element_text(face = "bold", size = 13, hjust = 0),
    plot.subtitle = element_text(size = 9.5, color = "grey40", hjust = 0, margin = margin(b = 10)),
    plot.margin = margin(14, 14, 10, 14)
  )

ggsave(FIG_OUT, p, width = 9, height = 7.6, dpi = 300, bg = "white")
message(sprintf("Wrote figure to %s", FIG_OUT))
