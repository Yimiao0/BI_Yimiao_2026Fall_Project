# EDA on the Step 3 stratum-arm table: correlation of ORR and median PFS with
# arm-level baseline characteristics, and ORR vs median PFS.
#
# Each row = one arm (or one stratum of an arm). Counts are converted to
# proportions using arm_sample_size as the denominator.
#
# Input:  data/raw/step3_stratum_arm_variables.xlsx (sheet "claude_collected")
# Output: results/eda/correlation_table.csv
#         figures/eda/distribution_variables.pdf
#         figures/eda/scatter_ORR_vs_covariates.pdf
#         figures/eda/scatter_mPFS_vs_covariates.pdf
#         figures/eda/boxplot_ORR_mPFS_by_moa.pdf
#         figures/eda/boxplot_ORR_mPFS_by_biomarker.pdf
#         figures/eda/scatter_ORR_vs_mPFS.pdf
#         figures/eda/correlation_heatmap.pdf

required_pkgs <- c("readxl", "dplyr", "tidyr", "ggplot2", "patchwork", "corrplot")
missing_pkgs <- setdiff(required_pkgs, rownames(installed.packages()))
if (length(missing_pkgs) > 0) install.packages(missing_pkgs)

library(readxl)
library(dplyr)
library(tidyr)
library(ggplot2)
library(patchwork)
library(corrplot)

DATA_IN <- "data/raw/step3_stratum_arm_variables.xlsx"
SHEET <- "claude_collected"
FIG_DIR <- "figures/eda"
RES_DIR <- "results/eda"

# Text sizes for slides: ggplot base font (pt), in-panel labels (mm), point size
BASE_SIZE <- 20
LABEL_SIZE <- 5.5
POINT_SIZE <- 2.4

dir.create(FIG_DIR, recursive = TRUE, showWarnings = FALSE)
dir.create(RES_DIR, recursive = TRUE, showWarnings = FALSE)

## ---- Load and derive arm-level covariates ------------------------------

raw_df <- read_excel(DATA_IN, sheet = SHEET)

STAGE_COLS <- c("stage_I_II", "stage_IIIA", "stage_IIIB", "stage_IIIB_wet", "stage_IIIC",
                "stage_IV", "stage_recurrent", "stage_Unknown")

# Proportion of the arm; NA when the numerator was not reported
prop_of_n <- function(count, n) ifelse(is.na(n) | n <= 0, NA_real_, count / n)

arm_df <- raw_df %>%
  # Drop non-NSCLC cohorts (basket trials, SCLC, melanoma, ...) flagged in notes
  filter(!grepl("NOT NSCLC", notes)) %>%
  mutate(
    tobacco_ever = coalesce(
      Tobacco_Ever,
      ifelse(is.na(Tobacco_Current) & is.na(Tobacco_Former), NA_real_,
             coalesce(Tobacco_Current, 0) + coalesce(Tobacco_Former, 0))
    ),
    female_prop = prop_of_n(female_count, arm_sample_size),
    # Among patients with known smoking status (unknown excluded from denominator)
    tobacco_ever_prop = prop_of_n(tobacco_ever, tobacco_ever + Tobacco_Never),
    ECOG_0_prop = prop_of_n(ECOG_0, arm_sample_size),
    squamous_prop = prop_of_n(squamous_count, arm_sample_size),
    # Stage IV among patients with known I-IV stage: unknown and recurrent are excluded
    # from the denominator; IIIB_wet is a subset of IIIB, so not added again.
    # Arms reporting any stage count unreported stage categories as 0.
    stage_reported = if_any(all_of(STAGE_COLS), ~ !is.na(.x)),
    stage_I_II_n = coalesce(stage_I_II, 0),
    stage_III_n = coalesce(stage_IIIA, 0) + coalesce(stage_IIIB, 0) + coalesce(stage_IIIC, 0),
    stage_IV_n = coalesce(stage_IV, 0),
    stage_known = ifelse(stage_reported, stage_I_II_n + stage_III_n + stage_IV_n, NA_real_),
    stage_IV_prop = prop_of_n(stage_IV_n, stage_known)
  )

covariates <- c(
  median_age = "Median age (years)",
  female_prop = "Female proportion",
  tobacco_ever_prop = "Ever-smoker proportion",
  ECOG_0_prop = "ECOG 0 proportion",
  squamous_prop = "Squamous proportion",
  stage_IV_prop = "Stage IV proportion"
)
outcomes <- c(ORR = "ORR", mPFS_months = "Median PFS (months)")

cat(sprintf("Rows analysed: %d (of %d)\n", nrow(arm_df), nrow(raw_df)))

## ---- Distribution of each variable -------------------------------------

all_vars <- c(outcomes, covariates)
dist_df <- arm_df %>%
  select(all_of(names(all_vars))) %>%
  pivot_longer(everything(), names_to = "variable", values_to = "value") %>%
  filter(!is.na(value)) %>%
  mutate(variable = factor(all_vars[variable], levels = all_vars))

dist_lab <- dist_df %>%
  group_by(variable) %>%
  summarise(label = sprintf("n = %d\nmean = %.2f\nmedian = %.2f", n(), mean(value), median(value)),
            .groups = "drop")

p_dist <- ggplot(dist_df, aes(value)) +
  geom_histogram(bins = 30, fill = "grey60", colour = "white") +
  geom_text(data = dist_lab, aes(x = Inf, y = Inf, label = label),
            hjust = 1.05, vjust = 1.1, size = LABEL_SIZE * 0.8, inherit.aes = FALSE) +
  # Headroom above the tallest bar for the three-line label
  scale_y_continuous(expand = expansion(mult = c(0.02, 0.7))) +
  facet_wrap(~ variable, scales = "free") +
  labs(x = NULL, y = "Number of arms") +
  theme_bw(base_size = BASE_SIZE)
ggsave(file.path(FIG_DIR, "distribution_variables.pdf"), p_dist, width = 15, height = 11)

## ---- Pairwise correlations ---------------------------------------------

# Pearson and Spearman on pairwise-complete rows
cor_pair <- function(df, x, y) {
  d <- df[complete.cases(df[, c(x, y)]), c(x, y)]
  n <- nrow(d)
  if (n < 4) {
    return(tibble(outcome = y, variable = x, n = n,
                  pearson_r = NA_real_, pearson_p = NA_real_,
                  spearman_rho = NA_real_, spearman_p = NA_real_))
  }
  pe <- cor.test(d[[x]], d[[y]], method = "pearson")
  sp <- suppressWarnings(cor.test(d[[x]], d[[y]], method = "spearman", exact = FALSE))
  tibble(outcome = y, variable = x, n = n,
         pearson_r = unname(pe$estimate), pearson_p = pe$p.value,
         spearman_rho = unname(sp$estimate), spearman_p = sp$p.value)
}

pairs <- c(
  unlist(lapply(names(outcomes), function(y)
    lapply(names(covariates), function(x) c(x, y))), recursive = FALSE),
  list(c("mPFS_months", "ORR"))
)
cor_tbl <- bind_rows(lapply(pairs, function(p) cor_pair(arm_df, p[1], p[2]))) %>%
  mutate(across(c(pearson_r, spearman_rho), ~ round(.x, 3)),
         across(c(pearson_p, spearman_p), ~ signif(.x, 3)))

write.csv(cor_tbl, file.path(RES_DIR, "correlation_table.csv"), row.names = FALSE)
print(as.data.frame(cor_tbl))

## ---- Scatter plots -----------------------------------------------------

FIRST_LINE_COLOURS <- c("First-line" = "#0072B2", "Pretreated" = "#D55E00")
first_line_label <- function(x) {
  factor(ifelse(x == 1, "First-line", "Pretreated"), levels = names(FIRST_LINE_COLOURS))
}

# Outcome by first-line status (maintenance counted as first-line), with n per
# group and a Wilcoxon rank-sum test; styled to sit next to the scatter facets
first_line_box <- function(df, outcome, y_limits) {
  d <- df %>%
    filter(!is.na(.data[[outcome]])) %>%
    mutate(group = first_line_label(first_line), panel = "First-line")
  test <- wilcox.test(d[[outcome]] ~ d$group, exact = FALSE)
  stars <- as.character(symnum(test$p.value, cutpoints = c(0, 0.001, 0.01, 0.05, 1),
                               symbols = c("***", "**", "*", "")))
  n_df <- count(d, group, panel)

  ggplot(d, aes(group, .data[[outcome]], fill = group)) +
    geom_boxplot(outlier.shape = NA, alpha = 0.5, width = 0.55) +
    geom_jitter(aes(colour = group), width = 0.15, height = 0, size = POINT_SIZE, alpha = 0.7) +
    geom_text(data = n_df, aes(x = group, y = -Inf, label = sprintf("n = %d", n)),
              vjust = -0.6, size = LABEL_SIZE, inherit.aes = FALSE) +
    annotate("text", x = -Inf, y = Inf, hjust = -0.05, vjust = 1.3, size = LABEL_SIZE,
             label = trimws(sprintf("Wilcoxon rank-sum test\np = %.2g %s", test$p.value, stars))) +
    scale_fill_manual(values = FIRST_LINE_COLOURS, guide = "none") +
    scale_colour_manual(values = FIRST_LINE_COLOURS, guide = "none") +
    scale_x_discrete(labels = c("First-line" = "First-\nline", "Pretreated" = "Pre-\ntreated")) +
    coord_cartesian(ylim = y_limits) +  # same limits and expansion as the scatters
    facet_wrap(~ panel) +
    labs(x = NULL, y = NULL) +
    theme_bw(base_size = BASE_SIZE)
}

scatter_panel <- function(df, outcome, out_file) {
  # Shared y range for scatters and first-line box, with room below for the box
  # n labels and above for the n / rho / p labels
  y_range <- range(df[[outcome]], na.rm = TRUE)
  y_limits <- y_range + c(-0.14, 0.35) * diff(y_range)

  long_df <- df %>%
    select(all_of(c(outcome, names(covariates)))) %>%
    pivot_longer(-all_of(outcome), names_to = "variable", values_to = "value") %>%
    filter(!is.na(value), !is.na(.data[[outcome]])) %>%
    mutate(variable = factor(covariates[variable], levels = covariates))

  lab_df <- cor_tbl %>%
    filter(outcome == !!outcome, variable %in% names(covariates)) %>%
    mutate(variable = factor(covariates[variable], levels = covariates),
           n_label = sprintf("n = %d", n),
           # plotmath, so "rho" is drawn as the Greek letter by the default pdf device
           rho_label = sprintf('Spearman~rho == "%.2f"~(p == "%.2g")', spearman_rho, spearman_p))

  p <- ggplot(long_df, aes(value, .data[[outcome]])) +
    geom_point(alpha = 0.6, size = POINT_SIZE * 0.8) +
    geom_smooth(method = "lm", se = TRUE, formula = y ~ x, linewidth = 1) +
    geom_text(data = lab_df, aes(x = -Inf, y = Inf, label = n_label),
              hjust = -0.05, vjust = 1.5, size = LABEL_SIZE * 0.85, inherit.aes = FALSE) +
    geom_text(data = lab_df, aes(x = -Inf, y = Inf, label = rho_label), parse = TRUE,
              hjust = -0.05, vjust = 2.7, size = LABEL_SIZE * 0.85, inherit.aes = FALSE) +
    coord_cartesian(ylim = y_limits) +
    facet_wrap(~ variable, scales = "free_x") +
    labs(x = NULL, y = outcomes[[outcome]]) +
    theme_bw(base_size = BASE_SIZE)

  # First-line boxplot on the right, on the same y range as the scatters
  p_all <- p + first_line_box(df, outcome, y_limits) + plot_layout(widths = c(3, 1))
  ggsave(out_file, p_all, width = 18, height = 10)
}

scatter_panel(arm_df, "ORR", file.path(FIG_DIR, "scatter_ORR_vs_covariates.pdf"))
scatter_panel(arm_df, "mPFS_months", file.path(FIG_DIR, "scatter_mPFS_vs_covariates.pdf"))

## ---- ORR and median PFS by first-line status (summary) -----------------

# Median (IQR) of each outcome by first-line status; the boxplots are the
# right-hand panel of the scatter_*_vs_covariates figures
print(arm_df %>%
        mutate(first_line_group = first_line_label(first_line)) %>%
        select(first_line_group, all_of(names(outcomes))) %>%
        pivot_longer(all_of(names(outcomes)), names_to = "outcome", values_to = "value") %>%
        filter(!is.na(value)) %>%
        group_by(outcome, first_line_group) %>%
        summarise(n = n(), median = median(value),
                  q1 = quantile(value, 0.25), q3 = quantile(value, 0.75), .groups = "drop"),
      n = Inf)

orr_pfs <- cor_tbl %>% filter(outcome == "ORR", variable == "mPFS_months")
p_orr_pfs <- ggplot(filter(arm_df, !is.na(ORR), !is.na(mPFS_months)),
                    aes(ORR, mPFS_months)) +
  geom_point(alpha = 0.6, size = POINT_SIZE) +
  geom_smooth(method = "lm", se = TRUE, formula = y ~ x, linewidth = 1) +
  labs(x = "ORR", y = "Median PFS (months)",
       subtitle = bquote(atop(.(sprintf("n = %d; Pearson r = %.2f (p = %.2g)",
                                        orr_pfs$n, orr_pfs$pearson_r, orr_pfs$pearson_p)),
                              "Spearman" ~ rho * .(sprintf(" = %.2f (p = %.2g)",
                                                           orr_pfs$spearman_rho, orr_pfs$spearman_p))))) +
  theme_bw(base_size = BASE_SIZE)
ggsave(file.path(FIG_DIR, "scatter_ORR_vs_mPFS.pdf"), p_orr_pfs, width = 9, height = 7.5)

## ---- Spearman correlation heatmap: every pair of variables ---------------
# Lower triangle only (no diagonal): Spearman rho, significance stars and
# pairwise n (pairwise complete rows); cell colour = rho. Cells are square.

heat_vars <- c(names(outcomes), names(covariates))
pairs_df <- as.data.frame(arm_df[, heat_vars])
# Short one-line names for this figure: no units, "proportion" abbreviated
pair_labels <- sub(" proportion$", " prop.",
                   sub(" \\((months|years)\\)$", "", c(outcomes, covariates)))

cor_pal <- COL2("RdBu", 200)  # corrplot diverging palette: -1 red to +1 blue
rho_colour <- function(r) cor_pal[round((r + 1) / 2 * 199) + 1]

# One cell with its bottom-left corner at (x0, y0), side 1
draw_cor_cell <- function(x, y, x0, y0, inset = 0.03) {
  ok <- complete.cases(x, y)
  rho <- suppressWarnings(cor.test(x[ok], y[ok], method = "spearman", exact = FALSE))
  r <- unname(rho$estimate)
  # Undefined when a variable is constant over the shared rows
  if (is.na(r)) {
    rect(x0 + inset, y0 + inset, x0 + 1 - inset, y0 + 1 - inset, border = "grey70")
    text(x0 + 0.5, y0 + 0.58, "NA", cex = 1.9, col = "grey50")
    text(x0 + 0.5, y0 + 0.2, sprintf("n = %d", sum(ok)), cex = 1.35, col = "grey50")
    return(invisible())
  }
  stars <- symnum(rho$p.value, cutpoints = c(0, 0.001, 0.01, 0.05, 1),
                  symbols = c("***", "**", "*", ""))
  rect(x0 + inset, y0 + inset, x0 + 1 - inset, y0 + 1 - inset,
       col = rho_colour(r), border = "grey70")
  txt_col <- if (abs(r) > 0.6) "white" else "black"
  text(x0 + 0.5, y0 + 0.58, sprintf("%.2f%s", r, stars), cex = 1.65, col = txt_col)
  text(x0 + 0.5, y0 + 0.2, sprintf("n = %d", sum(ok)), cex = 1.35, col = txt_col)
}

n_vars <- ncol(pairs_df)
n_cells <- n_vars - 1  # rows are variables 2..n, columns are variables 1..n-1

pdf(file.path(FIG_DIR, "correlation_heatmap.pdf"), width = 15, height = 12.5)
par(mar = c(12, 16, 6, 10))
plot.new()
plot.window(xlim = c(0, n_cells), ylim = c(0, n_cells), asp = 1)  # asp = 1: square cells
title(main = "Pairwise Spearman correlation", font.main = 1, cex.main = 2.6, line = 3)
mtext("* p<0.05, ** p<0.01, *** p<0.001", side = 3, line = 0.8, cex = 1.6)  # star key

for (i in 2:n_vars) {
  for (j in seq_len(i - 1)) {
    draw_cor_cell(pairs_df[[j]], pairs_df[[i]], x0 = j - 1, y0 = n_vars - i)
  }
}

# Variable names: columns along the bottom (angled so large text doesn't
# collide), rows down the left
text(seq_len(n_cells) - 0.35, -0.1, pair_labels[-n_vars], srt = 45,
     adj = c(1, 1), cex = 1.9, xpd = NA)
text(-0.1, n_cells - seq_len(n_cells) + 0.5, pair_labels[-1], adj = c(1, 0.5), cex = 1.9, xpd = NA)

# Colour scale to the right of the grid, spanning its full height
par(xpd = NA)
bar_x <- c(n_cells + 0.4, n_cells + 0.65)
bar_y <- c(0, n_cells)
bar_breaks <- seq(bar_y[1], bar_y[2], length.out = length(cor_pal) + 1)
rect(bar_x[1], head(bar_breaks, -1), bar_x[2], tail(bar_breaks, -1), col = cor_pal, border = NA)
rect(bar_x[1], bar_y[1], bar_x[2], bar_y[2])
tick_y <- bar_y[1] + (seq(-1, 1, 0.5) + 1) / 2 * diff(bar_y)
segments(bar_x[2], tick_y, bar_x[2] + 0.06, tick_y)
text(bar_x[2] + 0.1, tick_y, format(seq(-1, 1, 0.5), nsmall = 1), adj = c(0, 0.5), cex = 1.8)
text(mean(bar_x), bar_y[2] + 0.35, expression("Spearman " * rho), cex = 1.9)
dev.off()


## ---- Boxplots of ORR and median PFS by MOA combination --------------------
# Each arm's combination of MOA components (moa_* columns). Combinations with at
# least MIN_COMBO_ARMS arms get their own box, ordered by number of arms; the rest
# are pooled into "Other combinations". Points are coloured by first-line
# status, since line of therapy differs a lot between combinations.

MIN_COMBO_ARMS <- 10
MOA_COMPONENT_LABELS <- c(moa_chemo = "Chemo", moa_immune_checkpoint = "ICI",
                          moa_immune_other = "Other immune", moa_antiangio = "Anti-angio",
                          moa_targeted = "Targeted", moa_other = "Other agent")

moa_df <- arm_df %>%
  mutate(combo = apply(across(all_of(names(MOA_COMPONENT_LABELS))), 1, function(r) {
           parts <- MOA_COMPONENT_LABELS[r == 1]
           if (length(parts) == 0) "No active drug" else paste(parts, collapse = " + ")
         }),
         first_line_group = first_line_label(first_line))

combo_tab <- moa_df %>%
  group_by(combo) %>%
  summarise(arms = n(), patients = sum(arm_sample_size), .groups = "drop")
main_combos <- combo_tab$combo[combo_tab$arms >= MIN_COMBO_ARMS]

moa_df <- moa_df %>%
  mutate(combo_group = ifelse(combo %in% main_combos, combo, "Other combinations"))
combo_order <- c(combo_tab %>%
                   filter(combo %in% main_combos) %>%
                   arrange(desc(arms), desc(patients)) %>%
                   pull(combo),
                 "Other combinations")

moa_box_df <- moa_df %>%
  select(combo_group, first_line_group, all_of(names(outcomes))) %>%
  pivot_longer(all_of(names(outcomes)), names_to = "outcome", values_to = "value") %>%
  filter(!is.na(value)) %>%
  mutate(outcome = factor(outcomes[outcome], levels = outcomes),
         combo_group = factor(combo_group, levels = combo_order))

moa_n <- count(moa_box_df, outcome, combo_group)

p_moa <- ggplot(moa_box_df, aes(combo_group, value)) +
  geom_boxplot(outlier.shape = NA, fill = "grey90", width = 0.6) +
  geom_jitter(aes(colour = first_line_group), width = 0.15, height = 0, size = POINT_SIZE, alpha = 0.75) +
  geom_text(data = moa_n, aes(x = combo_group, y = -Inf, label = sprintf("n = %d", n)),
            vjust = -0.6, size = LABEL_SIZE, inherit.aes = FALSE) +
  scale_colour_manual(values = FIRST_LINE_COLOURS, name = NULL) +
  scale_x_discrete(labels = function(x) gsub(" \\+ ", " +\n", x)) +  # one agent per line
  scale_y_continuous(expand = expansion(mult = c(0.14, 0.05))) +  # room for n labels
  facet_wrap(~ outcome, ncol = 1, scales = "free_y") +
  labs(x = "MOA combination", y = NULL) +
  guides(colour = guide_legend(override.aes = list(size = 4))) +
  theme_bw(base_size = BASE_SIZE) +
  theme(legend.position = "top")
ggsave(file.path(FIG_DIR, "boxplot_ORR_mPFS_by_moa.pdf"), p_moa, width = 16, height = 11)

# Arms, patients, share first-line and median (IQR) outcomes per group, for reference
print(moa_df %>%
        group_by(combo_group) %>%
        summarise(arms = n(), patients = sum(arm_sample_size),
                  pct_first_line = round(100 * mean(first_line == 1)),
                  ORR_median = median(ORR, na.rm = TRUE),
                  ORR_q1 = quantile(ORR, 0.25, na.rm = TRUE), ORR_q3 = quantile(ORR, 0.75, na.rm = TRUE),
                  mPFS_median = median(mPFS_months, na.rm = TRUE),
                  mPFS_q1 = quantile(mPFS_months, 0.25, na.rm = TRUE),
                  mPFS_q3 = quantile(mPFS_months, 0.75, na.rm = TRUE)) %>%
        mutate(combo_group = factor(combo_group, levels = combo_order)) %>%
        arrange(combo_group) %>%
        as.data.frame(), digits = 2)
cat("Pooled into Other combinations:\n")
print(as.data.frame(filter(combo_tab, !combo %in% main_combos) %>% arrange(desc(arms))))


## ---- Boxplots of ORR and median PFS by biomarker match ---------------------
# biomarker_matched (add_derived_variables.R): 1 if the arm's population was
# selected on a validated predictive biomarker for a drug in the regimen. Arms
# are split by regimen class, since a match is only possible for targeted or
# checkpoint-inhibitor regimens ("No targeted or ICI": chemotherapy, anti-angiogenic
# or other agents only, so never matched); points are coloured by first-line status.
# Each panel with both groups shows the Wilcoxon rank-sum test p-value, with
# stars for significance (* p<0.05, ** p<0.01, *** p<0.001). Sized for slides.

BIOMARKER_COLOURS <- c("Matched biomarker" = "#009E73", "Not matched" = "grey55")
REGIMEN_CLASSES <- c("Targeted agent", "Checkpoint inhibitor (no targeted)", "No targeted or ICI")

bio_df <- arm_df %>%
  mutate(regimen_class = factor(ifelse(moa_targeted == 1, REGIMEN_CLASSES[1],
                                ifelse(moa_immune_checkpoint == 1, REGIMEN_CLASSES[2],
                                       REGIMEN_CLASSES[3])), levels = REGIMEN_CLASSES),
         matched = factor(ifelse(biomarker_matched == 1, "Matched biomarker", "Not matched"),
                          levels = names(BIOMARKER_COLOURS)),
         first_line_group = first_line_label(first_line))

bio_long <- bio_df %>%
  select(regimen_class, matched, first_line_group, all_of(names(outcomes))) %>%
  pivot_longer(all_of(names(outcomes)), names_to = "outcome", values_to = "value") %>%
  filter(!is.na(value)) %>%
  mutate(outcome = factor(outcomes[outcome], levels = outcomes))
bio_n <- count(bio_long, outcome, regimen_class, matched)

bio_test <- bio_long %>%
  group_by(outcome, regimen_class) %>%
  filter(n_distinct(matched) == 2) %>%
  summarise(p = wilcox.test(value ~ matched, exact = FALSE)$p.value, .groups = "drop") %>%
  mutate(stars = as.character(symnum(p, cutpoints = c(0, 0.001, 0.01, 0.05, 1),
                                     symbols = c("***", "**", "*", ""))),
         label = trimws(sprintf("Wilcoxon rank-sum test: p = %.2g %s", p, stars)))

p_bio <- ggplot(bio_long, aes(matched, value)) +
  geom_boxplot(aes(fill = matched), outlier.shape = NA, alpha = 0.35, width = 0.6) +
  geom_jitter(aes(colour = first_line_group), width = 0.15, height = 0, size = POINT_SIZE, alpha = 0.75) +
  geom_text(data = bio_n, aes(x = matched, y = -Inf, label = sprintf("n = %d", n)),
            vjust = -0.6, size = LABEL_SIZE, inherit.aes = FALSE) +
  geom_text(data = bio_test, aes(x = -Inf, y = Inf, label = label),
            hjust = -0.03, vjust = 1.3, size = LABEL_SIZE, inherit.aes = FALSE) +
  scale_fill_manual(values = BIOMARKER_COLOURS, guide = "none") +
  scale_colour_manual(values = FIRST_LINE_COLOURS, name = NULL) +
  scale_x_discrete(drop = TRUE, labels = c("Matched biomarker" = "Matched", "Not matched" = "Not\nmatched")) +
  scale_y_continuous(expand = expansion(mult = c(0.14, 0.18))) +  # room for n and p-value labels
  facet_grid(outcome ~ regimen_class, scales = "free", space = "free_x",
             labeller = labeller(regimen_class = label_wrap_gen(22))) +
  labs(x = NULL, y = NULL, caption = "* p<0.05, ** p<0.01, *** p<0.001") +
  guides(colour = guide_legend(override.aes = list(size = 4))) +
  theme_bw(base_size = BASE_SIZE) +
  theme(legend.position = "top")
ggsave(file.path(FIG_DIR, "boxplot_ORR_mPFS_by_biomarker.pdf"), p_bio, width = 14, height = 9)
print(as.data.frame(select(bio_test, -label)), digits = 3)

# Median outcomes by regimen class and biomarker match, and arms per selected population
print(bio_df %>%
        group_by(regimen_class, matched) %>%
        summarise(arms = n(), pct_first_line = round(100 * mean(first_line == 1)),
                  ORR_median = median(ORR, na.rm = TRUE),
                  mPFS_median = median(mPFS_months, na.rm = TRUE), .groups = "drop") %>%
        as.data.frame(), digits = 2)
print(count(bio_df, biomarker_group, biomarker_matched) %>% as.data.frame())
