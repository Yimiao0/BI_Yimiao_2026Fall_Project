# Figure 2 (nsclc_data_collection_workflow.md): PRISMA-style flow diagram of
# Step 2 Stages 1-2, starting from the publications found in Figure 1:
# access classification (paywalled / free) and the full-text ORR/PFS/KM
# keyword screen, ending with the stratum-arms kept in the Step 3 dataset.
#
# Fully reproducible from already-saved pipeline outputs -- no network calls.
# Every count is read straight off the columns 02_access_and_screen_europepmc.R
# writes and the sheets of the Step 3 workbook, so nothing is re-classified or
# re-screened here.
#
# Input:  data/raw/step2_nct_publication_links_with_doi.csv
#         data/raw/step3_stratum_arm_variables.xlsx (claude_collected,
#           irrelevant_arms, failed_open_free_papers sheets)
# Output: figures/figure2_publication_flow.png

required_pkgs <- c("dplyr", "ggplot2", "ragg", "readxl")
missing_pkgs <- setdiff(required_pkgs, rownames(installed.packages()))
if (length(missing_pkgs) > 0) install.packages(missing_pkgs)

library(dplyr)
library(ggplot2)
library(readxl)

LINKS_IN <- "data/raw/step2_nct_publication_links_with_doi.csv"
STEP3_IN <- "data/raw/step3_stratum_arm_variables.xlsx"
FIG_DIR <- "figures"
FIG_OUT <- file.path(FIG_DIR, "figure2_publication_flow.png")

dir.create(FIG_DIR, recursive = TRUE, showWarnings = FALSE)

## ---- Counts, read directly off the saved screening table ----------------

links_df <- read.csv(LINKS_IN, stringsAsFactors = FALSE)

n_doi <- nrow(links_df)                                        # publications found in Figure 1

searched <- links_df$access_type %in% c("open_access", "free_access") & !is.na(links_df$ORR_available)
n_searched <- sum(searched)

passed <- searched & links_df$ORR_available == 1 & links_df$PFS_available == 1 & links_df$KM_available == 1
n_pass <- sum(passed)
n_fail <- n_searched - n_pass

message(sprintf("Step 2 Stage 1: %d with DOI -> %d free full text searched", n_doi, n_searched))
message(sprintf("Step 2 Stage 2: %d mention ORR, PFS and KM / %d miss at least one", n_pass, n_fail))

## ---- Step 3 dataset, read off the workbook sheets -----------------------

arms_df <- read_excel(STEP3_IN, sheet = "claude_collected")
irrelevant_df <- read_excel(STEP3_IN, sheet = "irrelevant_arms")
failed_df <- read_excel(STEP3_IN, sheet = "failed_open_free_papers")

n_arms <- nrow(arms_df)
n_arm_trials <- n_distinct(arms_df$nct_id)
n_failed_papers <- nrow(failed_df)
n_irrelevant_arms <- nrow(irrelevant_df)
n_irrelevant_trials <- length(setdiff(irrelevant_df$nct_id, arms_df$nct_id))

message(sprintf("Step 3: %d papers -> %d no arm-level data -> %d arms out of scope -> %d arms from %d trials",
                 n_pass, n_failed_papers, n_irrelevant_arms, n_arms, n_arm_trials))

## ---- Palette (same as Figure 1) ----------------------------------------

GREEN_DARK <- "#1e5b3a"   # publications found
GREEN_MID  <- "#2f7d4f"   # intermediate stages
GREEN_OK   <- "#3f9a62"   # passed screen
GREEN_END  <- "#1e5b3a"   # final dataset
EXCL_FILL  <- "#eef1ef"   # excluded / failed
EXCL_LINE  <- "#9aa5a0"
EXCL_TEXT  <- "#3d4a44"
LINE_COL   <- "#7c8a83"
HEAD_COL   <- "#2f7d4f"
FONT       <- "Helvetica Neue"

## ---- Layout -----------------------------------------------------------

# Coordinates are abstract plot units (~0.87 in each at the saved size); the
# main flow runs down x = [0, MAIN_W].
MAIN_W <- 6.2; MAIN_H <- 1.3; GAP <- 1.3
EXCL_X0 <- MAIN_W + 0.7; EXCL_W <- 6.0
EXCL1_H <- 0.75; EXCL2_H <- 1.75
TERM_GAP <- 0.35; TERM_W <- (MAIN_W - TERM_GAP) / 2; TERM_H <- 1.5
FINAL_H <- 1.5
cx <- MAIN_W / 2

SZ_LABEL <- 5.0; SZ_N <- 6.4; SZ_EXCL_HEAD <- 5.0; SZ_EXCL_BODY <- 4.2
SZ_SUB <- 3.7; SZ_HEAD <- 5.8

y_a_top <- 0                          # publications with DOI
y_b_top <- y_a_top - MAIN_H - GAP     # free full text searched
y_fork  <- y_b_top - MAIN_H - 0.75    # horizontal fork line
y_t_top <- y_fork - 0.35              # terminal boxes
y_f_top <- y_t_top - TERM_H - 1.1     # final dataset

box <- function(id, xmin, xmax, ymax, h, fill, line = NA) {
  tibble(id = id, xmin = xmin, xmax = xmax, ymin = ymax - h, ymax = ymax, fill = fill, line = line)
}
excl1_mid <- (y_a_top - MAIN_H + y_b_top) / 2
excl2_mid <- (y_t_top - TERM_H + y_f_top) / 2
boxes <- bind_rows(
  box("a", 0, MAIN_W, y_a_top, MAIN_H, GREEN_DARK),
  box("b", 0, MAIN_W, y_b_top, MAIN_H, GREEN_MID),
  box("pass", 0, TERM_W, y_t_top, TERM_H, GREEN_OK),
  box("fail", TERM_W + TERM_GAP, MAIN_W, y_t_top, TERM_H, EXCL_FILL, EXCL_LINE),
  box("final", 0, TERM_W, y_f_top, FINAL_H, GREEN_END),
  box("x1", EXCL_X0, EXCL_X0 + EXCL_W, excl1_mid + EXCL1_H / 2, EXCL1_H, EXCL_FILL, EXCL_LINE),
  box("x2", EXCL_X0, EXCL_X0 + EXCL_W, excl2_mid + EXCL2_H / 2, EXCL2_H, EXCL_FILL, EXCL_LINE)
)

# Rounded-rectangle polygon (ggplot2 has no rounded geom_rect).
round_rect <- function(xmin, xmax, ymin, ymax, r = 0.12, n = 8) {
  arc <- function(x0, y0, a0) {
    a <- seq(a0, a0 + pi / 2, length.out = n)
    tibble(x = x0 + r * cos(a), y = y0 + r * sin(a))
  }
  bind_rows(arc(xmax - r, ymax - r, 0), arc(xmin + r, ymax - r, pi / 2),
            arc(xmin + r, ymin + r, pi), arc(xmax - r, ymin + r, 3 * pi / 2))
}
polys <- boxes %>%
  rowwise() %>%
  reframe(id = id, fill = fill, line = line, round_rect(xmin, xmax, ymin, ymax))

fmt <- function(x) format(x, big.mark = ",")
pct <- function(x) sprintf("%.1f%%", 100 * x / n_searched)

excl2_text <- paste0(
  "\u2022 papers without arm-level results: ", fmt(n_failed_papers), "\n",
  "\u2022 papers outside the analysis population\n   (not NSCLC, surgical, chemoradiation, etc.): ", fmt(n_irrelevant_trials)
)

## ---- Build the plot ----------------------------------------------------

arrow_spec <- arrow(length = unit(0.12, "in"), type = "closed")
LW <- 0.8

txt <- function(x, y, label, size, color = "white", bold = FALSE, ...) {
  annotate("text", x = x, y = y, label = label, size = size, color = color,
           fontface = if (bold) "bold" else "plain", family = FONT, ...)
}
# Bold plotmath "n[sub] = value" label (e.g. n_pub = 665), drawn with parse = TRUE.
n_lab <- function(value, sub = "pub", prefix = "") {
  sprintf('bold(%sn["%s"]~"= %s")', prefix, sub, value)
}
main_box_text <- function(y_top, label, n, sub) {
  list(txt(cx, y_top - 0.32, label, SZ_LABEL),
       txt(cx, y_top - 0.72, n_lab(fmt(n)), SZ_N, parse = TRUE),
       txt(cx, y_top - 1.06, sub, SZ_SUB))
}
excl_box_text <- function(mid, h, head, body) {
  list(txt(EXCL_X0 + 0.28, mid + h / 2 - 0.2, head, SZ_EXCL_HEAD, EXCL_TEXT, bold = TRUE, hjust = 0, vjust = 1),
       txt(EXCL_X0 + 0.28, mid + h / 2 - 0.58, body, SZ_EXCL_BODY, EXCL_TEXT, hjust = 0, vjust = 1, lineheight = 1.1))
}

p <- ggplot() +
  # vertical flow
  annotate("segment", x = cx, xend = cx, y = y_a_top - MAIN_H, yend = y_b_top + 0.05,
           color = LINE_COL, linewidth = LW, arrow = arrow_spec) +
  annotate("segment", x = cx, xend = cx, y = y_b_top - MAIN_H, yend = y_fork,
           color = LINE_COL, linewidth = LW) +
  annotate("segment", x = TERM_W / 2, xend = TERM_W / 2, y = y_t_top - TERM_H, yend = y_f_top + 0.05,
           color = LINE_COL, linewidth = LW, arrow = arrow_spec) +
  # branches to exclusion boxes
  annotate("segment", x = c(cx, TERM_W / 2), xend = EXCL_X0 - 0.04, y = c(excl1_mid, excl2_mid),
           yend = c(excl1_mid, excl2_mid), color = LINE_COL, linewidth = LW, arrow = arrow_spec) +
  # fork
  annotate("segment", x = TERM_W / 2, xend = MAIN_W - TERM_W / 2, y = y_fork, yend = y_fork,
           color = LINE_COL, linewidth = LW) +
  annotate("segment", x = c(TERM_W / 2, MAIN_W - TERM_W / 2), xend = c(TERM_W / 2, MAIN_W - TERM_W / 2),
           y = y_fork, yend = y_t_top + 0.05, color = LINE_COL, linewidth = LW, arrow = arrow_spec) +
  # boxes
  geom_polygon(data = polys, aes(x, y, group = id, fill = I(fill), color = I(line)), linewidth = 0.6) +
  main_box_text(y_a_top, "Publications found (CT.gov reference with DOI)", n_doi, "from Figure 1") +
  main_box_text(y_b_top, "Free full text searched", n_searched,
                "Europe PMC full text or PubMed Central copy") +
  txt(EXCL_X0 + 0.28, excl1_mid, n_lab(fmt(n_doi - n_searched), prefix = '"No free full text  "*'),
      SZ_EXCL_HEAD, EXCL_TEXT, hjust = 0, parse = TRUE) +
  excl_box_text(excl2_mid, EXCL2_H, "Excluded at data extraction", excl2_text) +
  # terminal boxes
  txt(TERM_W / 2, y_t_top - 0.3, "Passed keyword screen", SZ_LABEL, bold = TRUE) +
  txt(TERM_W / 2, y_t_top - 0.72, n_lab(sprintf("%s (%s)", fmt(n_pass), pct(n_pass))), SZ_N * 0.9, parse = TRUE) +
  txt(TERM_W / 2, y_t_top - 1.13, "mentions ORR, PFS\nand Kaplan-Meier", SZ_SUB, lineheight = 0.95) +
  txt(MAIN_W - TERM_W / 2, y_t_top - 0.3, "Failed keyword screen", SZ_LABEL, EXCL_TEXT, bold = TRUE) +
  txt(MAIN_W - TERM_W / 2, y_t_top - 0.72, n_lab(sprintf("%s (%s)", fmt(n_fail), pct(n_fail))),
      SZ_N * 0.9, EXCL_TEXT, parse = TRUE) +
  txt(MAIN_W - TERM_W / 2, y_t_top - 1.13, "misses at least one of\nORR, PFS, Kaplan-Meier", SZ_SUB, EXCL_TEXT, lineheight = 0.95) +
  # final dataset
  txt(TERM_W / 2, y_f_top - 0.3, "Final analysis dataset", SZ_LABEL, bold = TRUE) +
  txt(TERM_W / 2, y_f_top - 0.72, n_lab(fmt(n_arm_trials)), SZ_N * 0.9, parse = TRUE) +
  txt(TERM_W / 2, y_f_top - 1.15, n_lab(fmt(n_arms), "stratum-arm"), SZ_N * 0.9, parse = TRUE) +
  # step heading
  txt(0, y_a_top + 0.38, "STEPS 2\u20133  \u00b7  PUBLICATION ACCESS, SCREENING & DATA EXTRACTION", SZ_HEAD, HEAD_COL, bold = TRUE, hjust = 0) +
  coord_fixed(xlim = c(-0.05, EXCL_X0 + EXCL_W + 0.05),
              ylim = c(y_f_top - FINAL_H - 0.05, y_a_top + 0.65), expand = FALSE, clip = "off") +
  theme_void(base_family = FONT) +
  theme(
    plot.margin = margin(14, 16, 12, 16),
    plot.background = element_rect(fill = "white", color = NA)
  )

ggsave(FIG_OUT, p, device = ragg::agg_png, width = 12, height = 8.4, dpi = 300, bg = "white")
message(sprintf("Wrote figure to %s", FIG_OUT))
