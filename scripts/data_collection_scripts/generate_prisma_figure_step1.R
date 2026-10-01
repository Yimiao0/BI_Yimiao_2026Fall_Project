# Figure 1 (nsclc_data_collection_workflow.md): PRISMA-style flow diagram of
# Step 1: trial identification/filtering (Stages 1-2) and publication
# linkage (Stage 3).
#
# Fully reproducible from already-saved pipeline outputs -- no network calls
# AND no re-running of Step 1 filtering logic. Every count plotted here is
# read straight off the row counts of the CSVs those scripts already write --
# nothing is re-filtered or re-derived, so there's no risk of this script's
# copy of the filter rules drifting out of sync with 01_pull_ctgov_candidates.R.
#
# Input:  data/raw/step1_ctgov_raw_all_completed_interventional.csv (n0)
#         data/raw/step1_ctgov_candidate_trials.csv (n_candidates)
#         data/raw/step1_nct_publication_links.csv (match confidence breakdown)
# Output: figures/figure1_trial_flow.png

required_pkgs <- c("dplyr", "ggplot2", "ragg")
missing_pkgs <- setdiff(required_pkgs, rownames(installed.packages()))
if (length(missing_pkgs) > 0) install.packages(missing_pkgs)

library(dplyr)
library(ggplot2)

RAW_IN <- "data/raw/step1_ctgov_raw_all_completed_interventional.csv"
CANDIDATES_IN <- "data/raw/step1_ctgov_candidate_trials.csv"
LINKS_IN <- "data/raw/step1_nct_publication_links.csv"
FIG_DIR <- "figures"
FIG_OUT <- file.path(FIG_DIR, "figure1_trial_flow.png")

dir.create(FIG_DIR, recursive = TRUE, showWarnings = FALSE)

## ---- Step 1 attrition, read directly off the saved output row counts ---

n0 <- nrow(read.csv(RAW_IN, stringsAsFactors = FALSE)) # step1-stage1 results: broad search of completed interventional NSCLC trials
n_candidates <- nrow(read.csv(CANDIDATES_IN, stringsAsFactors = FALSE)) # step1-stage2 results: filtered results

message(sprintf("Step 1: identified %d -> candidates %d (%d excluded)", n0, n_candidates, n0 - n_candidates))

## ---- Stage 3 found/not-found breakdown from the saved linkage table ----

links_df <- read.csv(LINKS_IN, stringsAsFactors = FALSE)
n_searched <- nrow(links_df)
# Stage 3 drops duplicate-DOI records (only the earliest trial per paper is
# kept), so its table is shorter than the Step 1 candidate list. For the slide
# those dropped trials are simply counted as "no publication found".
n_dup_doi <- n_candidates - n_searched
n_found <- sum(links_df$confidence == "found")
n_not_found <- sum(links_df$confidence == "not_found") + n_dup_doi

message(sprintf("Step 1 Stage 3 outcome: searched %d -> found %d / not found %d",
                 n_searched, n_found, n_not_found))


## ---- Palette ----------------------------------------------------------

GREEN_DARK <- "#1e5b3a"   # identification
GREEN_MID  <- "#2f7d4f"   # candidates
GREEN_OK   <- "#3f9a62"   # publication found
EXCL_FILL  <- "#eef1ef"   # excluded (all exclusion boxes + no publication found)
EXCL_LINE  <- "#9aa5a0"
EXCL_TEXT  <- "#3d4a44"
LINE_COL   <- "#7c8a83"
HEAD_COL   <- "#2f7d4f"
FONT       <- "Helvetica Neue"

## ---- Layout -----------------------------------------------------------

# Sized for a 16:9 presentation slide. Coordinates are abstract plot units
# (~0.87 in each at the saved size); the main flow runs down x = [0, MAIN_W].
MAIN_W <- 6.2; MAIN_H <- 1.1
EXCL_X0 <- MAIN_W + 0.7; EXCL_W <- 6.0
TERM_GAP <- 0.35; TERM_W <- (MAIN_W - TERM_GAP) / 2; TERM_H <- 1.5
cx <- MAIN_W / 2

# Text sizes (ggplot mm units; x2.85 = pt).
SZ_LABEL <- 5.0; SZ_N <- 6.4; SZ_EXCL_HEAD <- 5.0; SZ_EXCL_BODY <- 4.2
SZ_SUB <- 3.7; SZ_HEAD <- 5.8

y_a_top <- 0                         # identification box
y_b_top <- y_a_top - MAIN_H - 0.95   # candidates box
y_fork  <- y_b_top - MAIN_H - 0.75   # horizontal fork line
y_t_top <- y_fork - 0.35             # terminal boxes

box <- function(id, xmin, xmax, ymax, h, fill, line = NA) {
  tibble(id = id, xmin = xmin, xmax = xmax, ymin = ymax - h, ymax = ymax, fill = fill, line = line)
}
boxes <- bind_rows(
  box("a", 0, MAIN_W, y_a_top, MAIN_H, GREEN_DARK),
  box("b", 0, MAIN_W, y_b_top, MAIN_H, GREEN_MID),
  box("found", 0, TERM_W, y_t_top, TERM_H, GREEN_OK),
  box("none", TERM_W + TERM_GAP, MAIN_W, y_t_top, TERM_H, EXCL_FILL, EXCL_LINE)
)

# Exclusion side-box, centred on the gap it branches from (it may extend
# alongside the main boxes, which keeps the vertical gap small).
excl1_mid <- (y_a_top - MAIN_H + y_b_top) / 2
EXCL1_H <- 2.05
excl <- box("x1", EXCL_X0, EXCL_X0 + EXCL_W, excl1_mid + EXCL1_H / 2, EXCL1_H, EXCL_FILL, EXCL_LINE)

# Rounded-rectangle polygon (ggplot2 has no rounded geom_rect).
round_rect <- function(xmin, xmax, ymin, ymax, r = 0.12, n = 8) {
  arc <- function(x0, y0, a0) {
    a <- seq(a0, a0 + pi / 2, length.out = n)
    tibble(x = x0 + r * cos(a), y = y0 + r * sin(a))
  }
  bind_rows(arc(xmax - r, ymax - r, 0), arc(xmin + r, ymax - r, pi / 2),
            arc(xmin + r, ymin + r, pi), arc(xmax - r, ymin + r, 3 * pi / 2))
}
polys <- bind_rows(boxes, excl) %>%
  rowwise() %>%
  reframe(id = id, fill = fill, line = line, round_rect(xmin, xmax, ymin, ymax))

fmt <- function(x) format(x, big.mark = ",")
pct <- function(x) sprintf("%.1f%%", 100 * x / n_candidates)

excl1_text <- paste0(
  "Not meeting all Step 1 criteria:\n",
  "\u2022 drug, biological, or combination product\n",
  "\u2022 primary purpose = treatment\n",
  "\u2022 phase 1/2, 2, 2/3, or 3\n",
  "\u2022 number of participants reported"
)

## ---- Build the plot ----------------------------------------------------

arrow_spec <- arrow(length = unit(0.12, "in"), type = "closed")
LW <- 0.8

txt <- function(x, y, label, size, color = "white", bold = FALSE, ...) {
  annotate("text", x = x, y = y, label = label, size = size, color = color,
           fontface = if (bold) "bold" else "plain", family = FONT, ...)
}

p <- ggplot() +
  # vertical flow
  annotate("segment", x = cx, xend = cx, y = y_a_top - MAIN_H, yend = y_b_top + 0.05,
           color = LINE_COL, linewidth = LW, arrow = arrow_spec) +
  annotate("segment", x = cx, xend = cx, y = y_b_top - MAIN_H, yend = y_fork,
           color = LINE_COL, linewidth = LW) +
  # branch to exclusion box
  annotate("segment", x = cx, xend = EXCL_X0 - 0.04, y = excl1_mid, yend = excl1_mid,
           color = LINE_COL, linewidth = LW, arrow = arrow_spec) +
  # fork
  annotate("segment", x = TERM_W / 2, xend = MAIN_W - TERM_W / 2, y = y_fork, yend = y_fork,
           color = LINE_COL, linewidth = LW) +
  annotate("segment", x = c(TERM_W / 2, MAIN_W - TERM_W / 2), xend = c(TERM_W / 2, MAIN_W - TERM_W / 2),
           y = y_fork, yend = y_t_top + 0.05, color = LINE_COL, linewidth = LW, arrow = arrow_spec) +
  # boxes
  geom_polygon(data = polys, aes(x, y, group = id, fill = I(fill), color = I(line)), linewidth = 0.6) +
  # identification / candidates
  txt(cx, y_a_top - 0.34, "Completed interventional NSCLC trials (CT.gov)", SZ_LABEL) +
  txt(cx, y_a_top - 0.77, sprintf("n = %s", fmt(n0)), SZ_N, bold = TRUE) +
  txt(cx, y_b_top - 0.34, "Candidate trials after Step 1 filtering", SZ_LABEL) +
  txt(cx, y_b_top - 0.77, sprintf("n = %s", fmt(n_candidates)), SZ_N, bold = TRUE) +
  # exclusions
  txt(EXCL_X0 + 0.28, excl1_mid + EXCL1_H / 2 - 0.2, sprintf("Excluded  n = %s", fmt(n0 - n_candidates)),
      SZ_EXCL_HEAD, EXCL_TEXT, bold = TRUE, hjust = 0, vjust = 1) +
  txt(EXCL_X0 + 0.28, excl1_mid + EXCL1_H / 2 - 0.58, excl1_text,
      SZ_EXCL_BODY, EXCL_TEXT, hjust = 0, vjust = 1, lineheight = 1.1) +
  # terminal boxes
  txt(TERM_W / 2, y_t_top - 0.3, "Publication found", SZ_LABEL, bold = TRUE) +
  txt(TERM_W / 2, y_t_top - 0.72, sprintf("n = %s (%s)", fmt(n_found), pct(n_found)), SZ_N * 0.9, bold = TRUE) +
  txt(TERM_W / 2, y_t_top - 1.13, "CT.gov RESULT/DERIVED\nreference with DOI", SZ_SUB, lineheight = 0.95) +
  txt(MAIN_W - TERM_W / 2, y_t_top - 0.3, "No publication found", SZ_LABEL, EXCL_TEXT, bold = TRUE) +
  txt(MAIN_W - TERM_W / 2, y_t_top - 0.72, sprintf("n = %s (%s)", fmt(n_not_found), pct(n_not_found)),
      SZ_N * 0.9, EXCL_TEXT, bold = TRUE) +
  txt(MAIN_W - TERM_W / 2, y_t_top - 1.13, "no RESULT/DERIVED\nreference with DOI", SZ_SUB, EXCL_TEXT, lineheight = 0.95) +
  # step heading
  txt(0, y_a_top + 0.38, "STEP 1  \u00b7  TRIAL IDENTIFICATION, FILTERING & PUBLICATION LINKAGE", SZ_HEAD, HEAD_COL, bold = TRUE, hjust = 0) +
  coord_fixed(xlim = c(-0.05, EXCL_X0 + EXCL_W + 0.05),
              ylim = c(y_t_top - TERM_H - 0.05, y_a_top + 0.65), expand = FALSE, clip = "off") +
  theme_void(base_family = FONT) +
  theme(
    plot.margin = margin(14, 16, 12, 16),
    plot.background = element_rect(fill = "white", color = NA)
  )

ggsave(FIG_OUT, p, device = ragg::agg_png, width = 12, height = 6.75, dpi = 300, bg = "white")
message(sprintf("Wrote figure to %s", FIG_OUT))
