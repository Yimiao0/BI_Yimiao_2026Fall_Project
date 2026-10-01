# Figures for covariate_rationales.md.
#
# Line of therapy: ORR and median PFS by first-line, second-line and third-line
# or later (line_of_therapy from tabulate_MOA_TrtStatus.R). Arms whose number of
# prior lines is unclear, maintenance and mixed arms are not shown. Boxes show
# the median and IQR; the diamond is the mean. Brackets give Wilcoxon rank-sum
# test p-values for second-line vs third-line or later, and first-line vs
# pretreated (second-line and later pooled).
#
# Model 2 outcome scale: residuals of Model 2 (observed ORR + default covariates,
# weighted by n_i, from data_modeling.R) fitted on median PFS in months vs log
# median PFS. Standardized residuals against fitted values, with the Spearman
# correlation of |residual| with fitted value (spread growing with the fitted
# value means non-constant variance). Arms with leverage 1 (fitted
# exactly, no defined standardized residual) are left out.
#
# Input:  data/raw/step3_stratum_arm_variables.xlsx (sheet "claude_collected")
#         data/raw/trtstatus_tabulation.csv
#         scripts/stat_method/data_modeling.R (sourced for the Model 2 data)
# Output: figures/rationales/line_of_therapy_ORR_mPFS.png
#         figures/rationales/mPFS_vs_log_mPFS_residuals.png

required_pkgs <- c("readxl", "dplyr", "tidyr", "ggplot2")
missing_pkgs <- setdiff(required_pkgs, rownames(installed.packages()))
if (length(missing_pkgs) > 0) install.packages(missing_pkgs)

library(readxl)
library(dplyr)
library(tidyr)
library(ggplot2)

DATA_IN <- "data/raw/step3_stratum_arm_variables.xlsx"
SHEET <- "claude_collected"
TRTSTATUS_IN <- "data/raw/trtstatus_tabulation.csv"
FIG_DIR <- "figures/rationales"

BASE_SIZE <- 20
LABEL_SIZE <- 5.5

dir.create(FIG_DIR, recursive = TRUE, showWarnings = FALSE)

LINES <- c("First-line", "Second-line", "Later lines")
LINE_LABELS <- c("First-line" = "First-line", "Second-line" = "Second-line",
                 "Later lines" = "Third-line\nor later")
LINE_COLOURS <- c("First-line" = "#0072B2", "Second-line" = "#E69F00", "Later lines" = "#D55E00")
OUTCOMES <- c(ORR = "ORR", mPFS_months = "Median PFS (months)")

line_map <- read.csv(TRTSTATUS_IN)[, c("participants_trt_status", "line_of_therapy")]
line_df <- read_excel(DATA_IN, sheet = SHEET) %>%
  left_join(line_map, by = "participants_trt_status") %>%
  filter(line_of_therapy %in% LINES) %>%
  select(line_of_therapy, all_of(names(OUTCOMES))) %>%
  pivot_longer(all_of(names(OUTCOMES)), names_to = "outcome", values_to = "value") %>%
  filter(!is.na(value)) %>%
  mutate(line_of_therapy = factor(line_of_therapy, levels = LINES),
         outcome = factor(OUTCOMES[outcome], levels = OUTCOMES))

stars <- function(p) as.character(symnum(p, cutpoints = c(0, 0.001, 0.01, 0.05, 1),
                                         symbols = c("***", "**", "*", "")))

# Per-group n, median and mean, drawn under each box
summ <- line_df %>%
  group_by(outcome, line_of_therapy) %>%
  summarise(n = n(), median = median(value), mean = mean(value), .groups = "drop") %>%
  mutate(label = sprintf("n = %d\nmedian %.2f\nmean %.2f", n, median, mean))

# Brackets: second vs later (x 2-3), first vs pretreated (x 1 to the 2-3 midpoint)
tests <- line_df %>%
  group_by(outcome) %>%
  summarise(
    p_2_vs_3 = wilcox.test(value[line_of_therapy == "Second-line"],
                           value[line_of_therapy == "Later lines"], exact = FALSE)$p.value,
    p_1_vs_pre = wilcox.test(value[line_of_therapy == "First-line"],
                             value[line_of_therapy != "First-line"], exact = FALSE)$p.value,
    top = max(value), range = diff(range(value)), .groups = "drop")
brackets <- bind_rows(
  tests %>% transmute(outcome, x = 2, xend = 3, y = top + 0.10 * range, p = p_2_vs_3),
  tests %>% transmute(outcome, x = 1, xend = 2.5, y = top + 0.30 * range, p = p_1_vs_pre)
) %>%
  mutate(label = trimws(sprintf("p = %.2g %s", p, stars(p))), tick = 0.03 * (y - 0))
print(as.data.frame(select(brackets, outcome, x, xend, p)), digits = 3)
print(as.data.frame(select(summ, -label)), digits = 3)

p <- ggplot(line_df, aes(line_of_therapy, value)) +
  geom_boxplot(aes(fill = line_of_therapy), outlier.shape = NA, alpha = 0.35, width = 0.6) +
  geom_jitter(aes(colour = line_of_therapy), width = 0.15, height = 0, size = 2.4, alpha = 0.7) +
  stat_summary(fun = mean, geom = "point", shape = 23, size = 5, fill = "white", colour = "black") +
  geom_segment(data = brackets, aes(x = x, xend = xend, y = y, yend = y), inherit.aes = FALSE) +
  geom_segment(data = brackets, aes(x = x, xend = x, y = y, yend = y - tick), inherit.aes = FALSE) +
  geom_segment(data = brackets, aes(x = xend, xend = xend, y = y, yend = y - tick), inherit.aes = FALSE) +
  geom_text(data = brackets, aes(x = (x + xend) / 2, y = y, label = label),
            vjust = -0.4, size = LABEL_SIZE, inherit.aes = FALSE) +
  geom_text(data = summ, aes(x = line_of_therapy, y = -Inf, label = label),
            vjust = -0.2, size = LABEL_SIZE * 0.8, lineheight = 0.9, inherit.aes = FALSE) +
  scale_fill_manual(values = LINE_COLOURS, guide = "none") +
  scale_colour_manual(values = LINE_COLOURS, guide = "none") +
  scale_x_discrete(labels = LINE_LABELS) +
  # room below for the summaries and above for the brackets; no ticks below 0
  scale_y_continuous(expand = expansion(mult = c(0.42, 0.12)),
                     breaks = function(lim) { b <- pretty(lim); b[b >= 0] }) +
  facet_wrap(~ outcome, scales = "free_y") +
  labs(x = NULL, y = NULL,
       caption = "Diamond = mean. Wilcoxon rank-sum test: * p<0.05, ** p<0.01, *** p<0.001") +
  theme_bw(base_size = BASE_SIZE)
ggsave(file.path(FIG_DIR, "line_of_therapy_ORR_mPFS.png"), p, width = 14, height = 8, dpi = 150)

## ---- Model 2: median PFS vs log median PFS residuals ----------------------------

source("scripts/stat_method/data_modeling.R")  # load_arm_data, prepare_model_data, DEFAULT_COVARIATES

prep <- prepare_model_data(load_arm_data(), DEFAULT_COVARIATES,
                           c("mPFS_months", "ORR", "arm_sample_size"))
m2_data <- prep$data
m2_rhs <- c("ORR", prep$covariates)
SCALES <- c(raw = "Median PFS (months)", log = "log(median PFS)")
fits <- list(
  raw = lm(reformulate(m2_rhs, response = "mPFS_months"), data = m2_data, weights = arm_sample_size),
  log = lm(reformulate(m2_rhs, response = "log(mPFS_months)"), data = m2_data, weights = arm_sample_size)
)

# Standardized residuals account for the weights and leverage, so both scales are comparable
resid_df <- bind_rows(lapply(names(fits), function(k) {
  f <- fits[[k]]
  r <- rstandard(f)
  ok <- is.finite(r)
  sp <- cor.test(abs(r[ok]), fitted(f)[ok], method = "spearman", exact = FALSE)
  data.frame(scale = SCALES[[k]], resid = r[ok], fitted = fitted(f)[ok],
             spread = sprintf("|residual| vs fitted: Spearman rho = %.2f, p = %.2g", sp$estimate, sp$p.value))
}))
resid_df$scale <- factor(resid_df$scale, levels = SCALES)
spread_lab <- distinct(resid_df, scale, spread)
print(as.data.frame(spread_lab))

p_resid <- ggplot(resid_df, aes(fitted, resid)) +
  geom_hline(yintercept = 0, colour = "grey50") +
  geom_point(alpha = 0.6, size = 2.4) +
  geom_text(data = spread_lab, aes(x = -Inf, y = Inf, label = spread),
            hjust = -0.03, vjust = 1.4, size = LABEL_SIZE * 0.8, inherit.aes = FALSE) +
  scale_y_continuous(expand = expansion(mult = c(0.05, 0.2))) +
  facet_wrap(~ scale, scales = "free_x") +
  labs(x = "Fitted value", y = "Standardized residual") +
  theme_bw(base_size = BASE_SIZE)
ggsave(file.path(FIG_DIR, "mPFS_vs_log_mPFS_residuals.png"), p_resid, width = 14, height = 6, dpi = 150)
