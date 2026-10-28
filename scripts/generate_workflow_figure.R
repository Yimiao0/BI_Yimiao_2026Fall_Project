# Project workflow figure: the four stages of the project (find trials, find
# and screen publications, collect data, modeling), with every sub-step
# marked as either an R script (with its file name) or the AI agent.
#
# Schematic only: counts are the Step 1-3 results in
# nsclc_data_collection_workflow.md, typed in by hand. No input files.
#
# Output: figures/figure0_project_workflow.png

required_pkgs <- c("dplyr", "ggplot2", "ragg")
missing_pkgs <- setdiff(required_pkgs, rownames(installed.packages()))
if (length(missing_pkgs) > 0) install.packages(missing_pkgs)

library(dplyr)
library(ggplot2)

FIG_OUT <- "figures/figure0_project_workflow.png"
dir.create("figures", recursive = TRUE, showWarnings = FALSE)

## ---- Palette (greens match Figures 1-2; amber marks the AI step) --------

HEAD_FILL <- "#1e5b3a"
R_LINE    <- "#2f7d4f"; R_FILL  <- "#e8f3ec"; R_TEXT  <- "#1e5b3a"
AI_LINE   <- "#c26a12"; AI_FILL <- "#fdf0e1"; AI_TEXT <- "#8a4708"
BODY_TEXT <- "#26302b"
SUB_TEXT  <- "#5b6862"
LINE_COL  <- "#7c8a83"
FONT      <- "Helvetica Neue"

## ---- Content ------------------------------------------------------------

stages <- tibble(
  col = 1:4,
  title = c("1  Find trials", "2  Find & screen papers", "3  Collect data", "4  Modeling")
)

# One row per sub-step; `tool` is the R file name(s) or "AI agent".
steps <- tribble(
  ~col, ~row, ~type, ~label,                                   ~tool,                                      ~result,
  1,    1,    "R",   "Pull NSCLC trials from the\nClinicalTrials.gov API and\napply inclusion criteria",
                                                              "01_pull_ctgov_candidates.R",               "1,580 candidate trials",
  2,    1,    "R",   "Link each trial to its\npublication DOI via PubMed",
                                                              "01b_link_nct_to_pubmed.R",                 "665 trials with a DOI",
  2,    2,    "R",   "Check free access and search\nfull text for ORR, PFS and KM\n(Europe PMC)",
                                                              "02_access_and_screen_europepmc.R",         "170 papers pass",
  3,    1,    "AI",  "Read each paper and fill the\nvariable list per stratum-arm\n(every row checked by hand)",
                                                              "AI agent",                                 "rows saved to Excel",
  3,    2,    "R",   "Move arms outside the analysis\npopulation (not NSCLC, surgical,\nchemoradiation)",
                                                              "03_filter_irrelevant_arms.R",              "199 stratum-arms",
  4,    1,    "R",   "Derive MOA, treatment-line and\nbiomarker variables",
                                                              "tabulate_MOA_TrtStatus.R\nadd_derived_variables.R", "",
  4,    2,    "R",   "Exploratory data analysis",          "EDA.R",                                    "",
  4,    3,    "R",   "Fit ORR and median PFS\nmodels, write report",
                                                              "data_modeling.R\nmodel_report.Rmd",        ""
)

## ---- Layout -------------------------------------------------------------

COL_W <- 4.5; COL_GAP <- 0.8
HEAD_H <- 0.75; HEAD_GAP <- 0.45
BOX_H <- 2.15; BOX_GAP <- 0.5

stages <- stages %>%
  mutate(xmin = (col - 1) * (COL_W + COL_GAP), xmax = xmin + COL_W, xc = (xmin + xmax) / 2)

steps <- steps %>%
  left_join(select(stages, col, xmin, xmax, xc), by = "col") %>%
  mutate(ymax = -HEAD_H - HEAD_GAP - (row - 1) * (BOX_H + BOX_GAP),
         ymin = ymax - BOX_H,
         line = ifelse(type == "AI", AI_LINE, R_LINE),
         fill = ifelse(type == "AI", AI_FILL, R_FILL),
         tagc = ifelse(type == "AI", AI_TEXT, R_TEXT),
         tag  = ifelse(type == "AI", "AI AGENT", "R SCRIPT"),
         lw   = ifelse(type == "AI", 1.4, 0.7))

# Rounded-rectangle polygon (ggplot2 has no rounded geom_rect).
round_rect <- function(xmin, xmax, ymin, ymax, r = 0.14, n = 8) {
  arc <- function(x0, y0, a0) {
    a <- seq(a0, a0 + pi / 2, length.out = n)
    tibble(x = x0 + r * cos(a), y = y0 + r * sin(a))
  }
  bind_rows(arc(xmax - r, ymax - r, 0), arc(xmin + r, ymax - r, pi / 2),
            arc(xmin + r, ymin + r, pi), arc(xmax - r, ymin + r, 3 * pi / 2))
}
head_polys <- stages %>% rowwise() %>%
  reframe(id = col, round_rect(xmin, xmax, -HEAD_H, 0))
box_polys <- steps %>% mutate(id = paste(col, row)) %>% rowwise() %>%
  reframe(id = id, fill = fill, line = line, lw = lw, round_rect(xmin, xmax, ymin, ymax))

# Tag pill in each box's top-left corner.
PILL_W <- 1.25; PILL_H <- 0.34
pills <- steps %>%
  mutate(pxmin = xmin + 0.2, pxmax = pxmin + PILL_W, pymax = ymax - 0.18, pymin = pymax - PILL_H)
pill_polys <- pills %>% mutate(id = paste(col, row)) %>% rowwise() %>%
  reframe(id = id, line = line, round_rect(pxmin, pxmax, pymin, pymax, r = 0.12))

y_bottom <- min(steps$ymin)
legend_y <- y_bottom - 0.75

arrow_spec <- arrow(length = unit(0.12, "in"), type = "closed")

# Arrows between stage headers, and down within a stage.
head_arrows <- stages %>% filter(col < 4) %>%
  transmute(x = xmax + 0.08, xend = xmax + COL_GAP - 0.1, y = -HEAD_H / 2)
down_arrows <- bind_rows(
  stages %>% transmute(col, x = xc, y = -HEAD_H, yend = -HEAD_H - HEAD_GAP + 0.04),
  steps %>% group_by(col) %>% filter(row < max(row)) %>% ungroup() %>%
    transmute(col, x = xc, y = ymin, yend = ymin - BOX_GAP + 0.04)
)

## ---- Plot ---------------------------------------------------------------

p <- ggplot() +
  annotate("segment", x = head_arrows$x, xend = head_arrows$xend, y = head_arrows$y, yend = head_arrows$y,
           color = LINE_COL, linewidth = 0.9, arrow = arrow_spec) +
  annotate("segment", x = down_arrows$x, xend = down_arrows$x, y = down_arrows$y, yend = down_arrows$yend,
           color = LINE_COL, linewidth = 0.8, arrow = arrow_spec) +
  geom_polygon(data = head_polys, aes(x, y, group = id), fill = HEAD_FILL) +
  geom_text(data = stages, aes(xc, -HEAD_H / 2, label = title), color = "white",
            size = 5.6, fontface = "bold", family = FONT) +
  geom_polygon(data = box_polys, aes(x, y, group = id, fill = I(fill), color = I(line), linewidth = I(lw))) +
  geom_polygon(data = pill_polys, aes(x, y, group = id, fill = I(line))) +
  geom_text(data = pills, aes((pxmin + pxmax) / 2, (pymin + pymax) / 2, label = tag),
            color = "white", size = 3.3, fontface = "bold", family = FONT) +
  geom_text(data = steps, aes(xmin + 0.22, ymax - 0.72, label = label), color = BODY_TEXT,
            size = 3.9, hjust = 0, vjust = 1, lineheight = 1.0, family = FONT) +
  geom_text(data = steps, aes(xmin + 0.22, ymin + 0.2, label = tool, color = I(tagc)),
            size = 3.25, hjust = 0, vjust = 0, fontface = "bold", lineheight = 1.0, family = "Menlo") +
  geom_text(data = filter(steps, result != ""), aes(xmax - 0.2, ymax - 0.35, label = result),
            color = SUB_TEXT, size = 3.4, hjust = 1, fontface = "italic", family = FONT) +
  # legend
  annotate("rect", xmin = 0, xmax = 0.4, ymin = legend_y - 0.15, ymax = legend_y + 0.15,
           fill = R_FILL, color = R_LINE, linewidth = 0.7) +
  annotate("text", x = 0.55, y = legend_y, label = "Runs with an R script (file name shown)",
           hjust = 0, size = 4.0, color = BODY_TEXT, family = FONT) +
  annotate("rect", xmin = 6.6, xmax = 7.0, ymin = legend_y - 0.15, ymax = legend_y + 0.15,
           fill = AI_FILL, color = AI_LINE, linewidth = 1.2) +
  annotate("text", x = 7.15, y = legend_y, label = "Needs the AI agent",
           hjust = 0, size = 4.0, color = BODY_TEXT, family = FONT) +
  coord_fixed(xlim = c(-0.05, max(stages$xmax) + 0.05), ylim = c(legend_y - 0.35, 0.05),
              expand = FALSE, clip = "off") +
  theme_void(base_family = FONT) +
  theme(plot.margin = margin(14, 16, 12, 16),
        plot.background = element_rect(fill = "white", color = NA))

ggsave(FIG_OUT, p, device = ragg::agg_png, width = 14, height = 6.6, dpi = 300, bg = "white")
message("Wrote ", FIG_OUT)
