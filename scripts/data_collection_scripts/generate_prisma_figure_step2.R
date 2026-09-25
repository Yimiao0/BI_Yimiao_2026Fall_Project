# Figure 2 (nsclc_data_collection_workflow.md): PRISMA-style flow diagram of
# Step 2 Stages 1-2, starting from the publications found in Figure 1:
# access classification (paywalled / free) and the full-text ORR/PFS/KM
# keyword screen.
#
# Fully reproducible from already-saved pipeline outputs -- no network calls.
# Every count is read straight off the columns 02_access_and_screen_europepmc.R
# writes, so nothing is re-classified or re-screened here.
#
# Input:  data/raw/step2_nct_publication_links_with_doi.csv
# Output: figures/figure2_publication_flow.png

required_pkgs <- c("dplyr", "ggplot2", "ragg")
missing_pkgs <- setdiff(required_pkgs, rownames(installed.packages()))
if (length(missing_pkgs) > 0) install.packages(missing_pkgs)

library(dplyr)
library(ggplot2)

LINKS_IN <- "data/raw/step2_nct_publication_links_with_doi.csv"
FIG_DIR <- "figures"
FIG_OUT <- file.path(FIG_DIR, "figure2_publication_flow.png")

dir.create(FIG_DIR, recursive = TRUE, showWarnings = FALSE)

## ---- Counts, read directly off the saved screening table ----------------

links_df <- read.csv(LINKS_IN, stringsAsFactors = FALSE)
n_type <- function(type) sum(links_df$access_type == type)

n_doi <- nrow(links_df)                                        # publications found in Figure 1
n_paywalled <- n_type("paywalled")
n_not_in_epmc <- n_type("not_in_europepmc")
n_lookup_failed <- n_type("lookup_failed")
n_open <- n_type("open_access")
n_free <- n_type("free_access")
n_readable <- n_open + n_free

searched <- links_df$access_type %in% c("open_access", "free_access") & !is.na(links_df$ORR_available)
n_searched <- sum(searched)
n_free_no_text <- sum(links_df$access_type == "free_access" & !searched)
n_open_no_text <- sum(links_df$access_type == "open_access" & !searched)

passed <- searched & links_df$ORR_available == 1 & links_df$PFS_available == 1 & links_df$KM_available == 1
n_pass <- sum(passed)
n_fail <- n_searched - n_pass

message(sprintf("Step 2 Stage 1: %d with DOI -> %d free to read (%d open, %d free) -> %d full text searched",
                 n_doi, n_readable, n_open, n_free, n_searched))
message(sprintf("Step 2 Stage 2: %d mention ORR, PFS and KM / %d miss at least one", n_pass, n_fail))

## ---- Palette (same as Figure 1) ----------------------------------------

GREEN_DARK <- "#1e5b3a"   # publications found
GREEN_MID  <- "#2f7d4f"   # intermediate stages
GREEN_OK   <- "#3f9a62"   # passed screen
EXCL_FILL  <- "#eef1ef"   # excluded / failed
EXCL_LINE  <- "#9aa5a0"
EXCL_TEXT  <- "#3d4a44"
LINE_COL   <- "#7c8a83"
HEAD_COL   <- "#2f7d4f"
FONT       <- "Helvetica Neue"

## ---- Layout -----------------------------------------------------------

# Coordinates are abstract plot units (~0.87 in each at the saved size); the
# main flow runs down x = [0, MAIN_W].
MAIN_W <- 6.2; MAIN_H <- 1.3; GAP <- 0.95
EXCL_X0 <- MAIN_W + 0.7; EXCL_W <- 6.0; EXCL_H <- 1.55
TERM_GAP <- 0.35; TERM_W <- (MAIN_W - TERM_GAP) / 2; TERM_H <- 1.5
cx <- MAIN_W / 2

SZ_LABEL <- 5.0; SZ_N <- 6.4; SZ_EXCL_HEAD <- 5.0; SZ_EXCL_BODY <- 4.2
SZ_SUB <- 3.7; SZ_HEAD <- 5.8

y_a_top <- 0                          # publications with DOI
y_b_top <- y_a_top - MAIN_H - GAP     # free to read
y_c_top <- y_b_top - MAIN_H - GAP     # full text searched
y_fork  <- y_c_top - MAIN_H - 0.75    # horizontal fork line
y_t_top <- y_fork - 0.35              # terminal boxes

box <- function(id, xmin, xmax, ymax, h, fill, line = NA) {
  tibble(id = id, xmin = xmin, xmax = xmax, ymin = ymax - h, ymax = ymax, fill = fill, line = line)
}
excl1_mid <- (y_a_top - MAIN_H + y_b_top) / 2
excl2_mid <- (y_b_top - MAIN_H + y_c_top) / 2
boxes <- bind_rows(
  box("a", 0, MAIN_W, y_a_top, MAIN_H, GREEN_DARK),
  box("b", 0, MAIN_W, y_b_top, MAIN_H, GREEN_MID),
  box("c", 0, MAIN_W, y_c_top, MAIN_H, GREEN_MID),
  box("pass", 0, TERM_W, y_t_top, TERM_H, GREEN_OK),
  box("fail", TERM_W + TERM_GAP, MAIN_W, y_t_top, TERM_H, EXCL_FILL, EXCL_LINE),
  box("x1", EXCL_X0, EXCL_X0 + EXCL_W, excl1_mid + EXCL_H / 2, EXCL_H, EXCL_FILL, EXCL_LINE),
  box("x2", EXCL_X0, EXCL_X0 + EXCL_W, excl2_mid + EXCL_H / 2, EXCL_H, EXCL_FILL, EXCL_LINE)
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
bullets <- function(labels, counts) {
  keep <- counts > 0
  paste0("\u2022 ", labels[keep], ": ", sapply(counts[keep], fmt), collapse = "\n")
}

excl1_text <- bullets(c("paywalled (subscription required)", "not in Europe PMC", "Europe PMC lookup failed"),
                      c(n_paywalled, n_not_in_epmc, n_lookup_failed))
excl2_text <- bullets(c("free, but only on journal sites that\n   block automated download", "open access, download failed"),
                      c(n_free_no_text, n_open_no_text))

## ---- Build the plot ----------------------------------------------------

arrow_spec <- arrow(length = unit(0.12, "in"), type = "closed")
LW <- 0.8

txt <- function(x, y, label, size, color = "white", bold = FALSE, ...) {
  annotate("text", x = x, y = y, label = label, size = size, color = color,
           fontface = if (bold) "bold" else "plain", family = FONT, ...)
}
main_box_text <- function(y_top, label, n, sub) {
  list(txt(cx, y_top - 0.32, label, SZ_LABEL),
       txt(cx, y_top - 0.72, sprintf("n = %s", fmt(n)), SZ_N, bold = TRUE),
       txt(cx, y_top - 1.06, sub, SZ_SUB))
}
excl_box_text <- function(mid, head, body) {
  list(txt(EXCL_X0 + 0.28, mid + EXCL_H / 2 - 0.2, head, SZ_EXCL_HEAD, EXCL_TEXT, bold = TRUE, hjust = 0, vjust = 1),
       txt(EXCL_X0 + 0.28, mid + EXCL_H / 2 - 0.58, body, SZ_EXCL_BODY, EXCL_TEXT, hjust = 0, vjust = 1, lineheight = 1.1))
}

p <- ggplot() +
  # vertical flow
  annotate("segment", x = cx, xend = cx, y = c(y_a_top, y_b_top) - MAIN_H, yend = c(y_b_top, y_c_top) + 0.05,
           color = LINE_COL, linewidth = LW, arrow = arrow_spec) +
  annotate("segment", x = cx, xend = cx, y = y_c_top - MAIN_H, yend = y_fork,
           color = LINE_COL, linewidth = LW) +
  # branches to exclusion boxes
  annotate("segment", x = cx, xend = EXCL_X0 - 0.04, y = c(excl1_mid, excl2_mid), yend = c(excl1_mid, excl2_mid),
           color = LINE_COL, linewidth = LW, arrow = arrow_spec) +
  # fork
  annotate("segment", x = TERM_W / 2, xend = MAIN_W - TERM_W / 2, y = y_fork, yend = y_fork,
           color = LINE_COL, linewidth = LW) +
  annotate("segment", x = c(TERM_W / 2, MAIN_W - TERM_W / 2), xend = c(TERM_W / 2, MAIN_W - TERM_W / 2),
           y = y_fork, yend = y_t_top + 0.05, color = LINE_COL, linewidth = LW, arrow = arrow_spec) +
  # boxes
  geom_polygon(data = polys, aes(x, y, group = id, fill = I(fill), color = I(line)), linewidth = 0.6) +
  main_box_text(y_a_top, "Publications found (CT.gov reference with DOI)", n_doi, "from Figure 1") +
  main_box_text(y_b_top, "Free to read", n_readable,
                sprintf("%s open access  \u00b7  %s free access", fmt(n_open), fmt(n_free))) +
  main_box_text(y_c_top, "Full text searched", n_searched,
                "Europe PMC full text or PubMed Central copy") +
  excl_box_text(excl1_mid, sprintf("Not free to read  n = %s", fmt(n_doi - n_readable)), excl1_text) +
  excl_box_text(excl2_mid, sprintf("Full text not retrieved  n = %s", fmt(n_readable - n_searched)), excl2_text) +
  # terminal boxes
  txt(TERM_W / 2, y_t_top - 0.3, "Passed keyword screen", SZ_LABEL, bold = TRUE) +
  txt(TERM_W / 2, y_t_top - 0.72, sprintf("n = %s (%s)", fmt(n_pass), pct(n_pass)), SZ_N * 0.9, bold = TRUE) +
  txt(TERM_W / 2, y_t_top - 1.13, "mentions ORR, PFS\nand Kaplan-Meier", SZ_SUB, lineheight = 0.95) +
  txt(MAIN_W - TERM_W / 2, y_t_top - 0.3, "Failed keyword screen", SZ_LABEL, EXCL_TEXT, bold = TRUE) +
  txt(MAIN_W - TERM_W / 2, y_t_top - 0.72, sprintf("n = %s (%s)", fmt(n_fail), pct(n_fail)),
      SZ_N * 0.9, EXCL_TEXT, bold = TRUE) +
  txt(MAIN_W - TERM_W / 2, y_t_top - 1.13, "misses at least one of\nORR, PFS, Kaplan-Meier", SZ_SUB, EXCL_TEXT, lineheight = 0.95) +
  # step heading
  txt(0, y_a_top + 0.38, "STEP 2  \u00b7  PUBLICATION ACCESS & SCREENING", SZ_HEAD, HEAD_COL, bold = TRUE, hjust = 0) +
  coord_fixed(xlim = c(-0.05, EXCL_X0 + EXCL_W + 0.05),
              ylim = c(y_t_top - TERM_H - 0.05, y_a_top + 0.65), expand = FALSE, clip = "off") +
  theme_void(base_family = FONT) +
  labs(title = "Publication access classification and full-text screening") +
  theme(
    plot.title = element_text(face = "bold", size = 20, color = "#1f2a24", margin = margin(b = 10)),
    plot.margin = margin(14, 16, 12, 16),
    plot.background = element_rect(fill = "white", color = NA)
  )

ggsave(FIG_OUT, p, device = ragg::agg_png, width = 12, height = 8.4, dpi = 300, bg = "white")
message(sprintf("Wrote figure to %s", FIG_OUT))
