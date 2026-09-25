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
#         figures/eda/scatter_ORR_vs_mPFS.pdf
#         figures/eda/correlation_heatmap.pdf
#         figures/eda/scatterplot_matrix.pdf

required_pkgs <- c("readxl", "dplyr", "tidyr", "ggplot2", "corrplot")
missing_pkgs <- setdiff(required_pkgs, rownames(installed.packages()))
if (length(missing_pkgs) > 0) install.packages(missing_pkgs)

library(readxl)
library(dplyr)
library(tidyr)
library(ggplot2)
library(corrplot)

DATA_IN <- "data/raw/step3_stratum_arm_variables.xlsx"
SHEET <- "claude_collected"
FIG_DIR <- "figures/eda"
RES_DIR <- "results/eda"

# TRUE = keep only unstratified rows (stratum == "all"), so no patient is
# counted twice across overlapping subgroups of the same arm.
ONLY_ALL_STRATUM <- FALSE

dir.create(FIG_DIR, recursive = TRUE, showWarnings = FALSE)
dir.create(RES_DIR, recursive = TRUE, showWarnings = FALSE)

## ---- Load and derive arm-level covariates ------------------------------

raw_df <- read_excel(DATA_IN, sheet = SHEET)

# Proportion of the arm; NA when the numerator was not reported
prop_of_n <- function(count, n) ifelse(is.na(n) | n <= 0, NA_real_, count / n)

arm_df <- raw_df %>%
  # Drop non-NSCLC cohorts (basket trials, SCLC, melanoma, ...) flagged in notes
  filter(!grepl("NOT NSCLC", notes)) %>%
  { if (ONLY_ALL_STRATUM) filter(., stratum == "all") else . } %>%
  mutate(
    tobacco_ever = coalesce(
      Tobacco_Ever,
      ifelse(is.na(Tobacco_Current) & is.na(Tobacco_Former), NA_real_,
             coalesce(Tobacco_Current, 0) + coalesce(Tobacco_Former, 0))
    ),
    female_prop = prop_of_n(female_count, arm_sample_size),
    tobacco_ever_prop = prop_of_n(tobacco_ever, arm_sample_size),
    ECOG_0_prop = prop_of_n(ECOG_0, arm_sample_size),
    squamous_prop = prop_of_n(squamous_count, arm_sample_size),
    stage_IV_prop = prop_of_n(stage_IV, arm_sample_size)
  )

covariates <- c(
  median_age = "Median age (years)",
  female_prop = "Female proportion",
  tobacco_ever_prop = "Ever-smoker proportion",
  ECOG_0_prop = "ECOG 0 proportion",
  squamous_prop = "Squamous proportion",
  stage_IV_prop = "Stage IV proportion",
  arm_sample_size = "Arm sample size"
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
  summarise(label = sprintf("n = %d\nmedian = %.2f", n(), median(value)), .groups = "drop")

p_dist <- ggplot(dist_df, aes(value)) +
  geom_histogram(bins = 30, fill = "grey60", colour = "white") +
  geom_text(data = dist_lab, aes(x = Inf, y = Inf, label = label),
            hjust = 1.05, vjust = 1.1, size = 3, inherit.aes = FALSE) +
  facet_wrap(~ variable, scales = "free") +
  labs(x = NULL, y = "Number of arms") +
  theme_bw()
ggsave(file.path(FIG_DIR, "distribution_variables.pdf"), p_dist, width = 11, height = 8)

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

scatter_panel <- function(df, outcome, out_file) {
  long_df <- df %>%
    select(all_of(c(outcome, names(covariates)))) %>%
    pivot_longer(-all_of(outcome), names_to = "variable", values_to = "value") %>%
    filter(!is.na(value), !is.na(.data[[outcome]])) %>%
    mutate(variable = factor(covariates[variable], levels = covariates))

  lab_df <- cor_tbl %>%
    filter(outcome == !!outcome, variable %in% names(covariates)) %>%
    mutate(variable = factor(covariates[variable], levels = covariates),
           label = sprintf("n = %d\nrho = %.2f (p = %.2g)", n, spearman_rho, spearman_p))

  p <- ggplot(long_df, aes(value, .data[[outcome]])) +
    geom_point(alpha = 0.6, size = 1.6) +
    geom_smooth(method = "lm", se = TRUE, formula = y ~ x, linewidth = 0.7) +
    geom_text(data = lab_df, aes(x = -Inf, y = Inf, label = label),
              hjust = -0.05, vjust = 1.1, size = 3, inherit.aes = FALSE) +
    facet_wrap(~ variable, scales = "free_x") +
    labs(x = NULL, y = outcomes[[outcome]]) +
    theme_bw()
  ggsave(out_file, p, width = 11, height = 7)
}

scatter_panel(arm_df, "ORR", file.path(FIG_DIR, "scatter_ORR_vs_covariates.pdf"))
scatter_panel(arm_df, "mPFS_months", file.path(FIG_DIR, "scatter_mPFS_vs_covariates.pdf"))

orr_pfs <- cor_tbl %>% filter(outcome == "ORR", variable == "mPFS_months")
p_orr_pfs <- ggplot(filter(arm_df, !is.na(ORR), !is.na(mPFS_months)),
                    aes(mPFS_months, ORR)) +
  geom_point(alpha = 0.6, size = 1.8) +
  geom_smooth(method = "lm", se = TRUE, formula = y ~ x, linewidth = 0.7) +
  labs(x = "Median PFS (months)", y = "ORR",
       subtitle = sprintf("n = %d; Pearson r = %.2f (p = %.2g); Spearman rho = %.2f (p = %.2g)",
                          orr_pfs$n, orr_pfs$pearson_r, orr_pfs$pearson_p,
                          orr_pfs$spearman_rho, orr_pfs$spearman_p)) +
  theme_bw()
ggsave(file.path(FIG_DIR, "scatter_ORR_vs_mPFS.pdf"), p_orr_pfs, width = 6, height = 5)

## ---- Spearman correlation heatmap (pairwise complete) -------------------

heat_vars <- c(names(outcomes), names(covariates))
heat_mat <- cor(arm_df[, heat_vars], method = "spearman", use = "pairwise.complete.obs")
dimnames(heat_mat) <- list(c(outcomes, covariates), c(outcomes, covariates))

pdf(file.path(FIG_DIR, "correlation_heatmap.pdf"), width = 8, height = 8)
corrplot(heat_mat, method = "color", type = "lower", addCoef.col = "black",
         number.cex = 0.7, tl.col = "black", tl.srt = 45, diag = FALSE,
         title = "Spearman correlation (pairwise complete)", mar = c(0, 0, 2, 0))
dev.off()

## ---- Scatterplot matrix: every pair of variables -------------------------
# Lower: scatter + linear fit; diagonal: histogram;
# upper: Spearman rho and pairwise n (cell colour = rho, same palette as heatmap).

pairs_df <- as.data.frame(arm_df[, heat_vars])
pair_labels <- gsub(" ", "\n", c(outcomes, covariates))

panel_scatter <- function(x, y, ...) {
  points(x, y, pch = 16, cex = 0.5, col = adjustcolor("grey30", 0.5))
  ok <- complete.cases(x, y)
  if (sum(ok) > 3) abline(lm(y[ok] ~ x[ok]), col = "steelblue", lwd = 1.2)
}

panel_hist <- function(x, ...) {
  usr <- par("usr")
  on.exit(par(usr = usr))
  h <- hist(x, breaks = 20, plot = FALSE)
  par(usr = c(usr[1:2], 0, max(h$counts) * 1.1))
  rect(head(h$breaks, -1), 0, tail(h$breaks, -1), h$counts, col = "grey70", border = "white")
  # Record where this diagonal panel sits on the device, for the axis names
  diag_ndc[[length(diag_ndc) + 1]] <<- c(
    x = grconvertX(0.5, "npc", "ndc"), y = grconvertY(0.5, "npc", "ndc"),
    left = grconvertX(0, "npc", "ndc"), bottom = grconvertY(0, "npc", "ndc"))
}

panel_cor <- function(x, y, ...) {
  usr <- par("usr")
  on.exit(par(usr = usr))
  par(usr = c(0, 1, 0, 1))
  ok <- complete.cases(x, y)
  rho <- suppressWarnings(cor.test(x[ok], y[ok], method = "spearman", exact = FALSE))
  stars <- symnum(rho$p.value, cutpoints = c(0, 0.001, 0.01, 0.05, 1),
                  symbols = c("***", "**", "*", ""))
  r <- unname(rho$estimate)
  # Same diverging palette as the corrplot heatmap: -1 (red) to +1 (blue)
  rect(0, 0, 1, 1, col = cor_pal[round((r + 1) / 2 * 199) + 1], border = NA)
  txt_col <- if (abs(r) > 0.6) "white" else "black"
  text(0.5, 0.55, sprintf("%.2f%s", r, stars), cex = 2, col = txt_col)
  text(0.5, 0.2, sprintf("n = %d", sum(ok)), cex = 1.1, col = txt_col)
}

cor_pal <- COL2("RdBu", 200)

n_vars <- length(pair_labels)
diag_ndc <- list()

pdf(file.path(FIG_DIR, "scatterplot_matrix.pdf"), width = 14, height = 13)
# Outer margins leave room for names on bottom/left and the colour bar on right
pairs(pairs_df, labels = rep("", n_vars), lower.panel = panel_scatter,
      diag.panel = panel_hist, upper.panel = panel_cor, gap = 0.3, oma = c(12, 16, 5, 14),
      main = "Pairwise relations (upper: Spearman rho; * p<0.05, ** p<0.01, *** p<0.001)")

# Variable names, drawn on a full-device overlay at the recorded panel centres
pos <- do.call(rbind, diag_ndc)
par(oma = c(0, 0, 0, 0), mar = c(0, 0, 0, 0), fig = c(0, 1, 0, 1), new = TRUE)
plot.new()
par(usr = c(0, 1, 0, 1))
text(pos[, "x"], min(pos[, "bottom"]) - 0.035, pair_labels, adj = c(0.5, 1), cex = 1.3, xpd = NA)
text(min(pos[, "left"]) - 0.04, pos[, "y"], pair_labels, adj = c(1, 0.5), cex = 1.3, xpd = NA)

# Colour scale for the upper-panel cells, placed in the right outer margin
par(fig = c(0.93, 0.95, 0.3, 0.7), mar = c(0, 0, 0, 0), new = TRUE)
image(1, seq(-1, 1, length.out = length(cor_pal)), t(seq_along(cor_pal)),
      col = cor_pal, axes = FALSE, xlab = "", ylab = "")
axis(4, at = seq(-1, 1, 0.5), las = 1, cex.axis = 0.9)
box()
mtext("Spearman rho", side = 3, line = 0.8, cex = 0.9)
dev.off()
