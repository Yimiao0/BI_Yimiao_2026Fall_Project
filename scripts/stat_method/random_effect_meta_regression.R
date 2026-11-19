# Random-effects meta-regression for log median PFS (arm level).
#
# Same mean model as Model 2 in data_modeling.R (observed ORR + covariates), but the
# residual is split into sampling error and true between-arm heterogeneity:
#
#   y_i = log(mPFS_i) = theta_0 + theta_p * ORR_i + theta^T x_i + u_i + e_i
#   u_i ~ N(0, tau^2)   true deviation of arm i from the model prediction
#   e_i ~ N(0, v_i)     sampling error of the reported median, v_i known
#
# v_i comes from the reported 95% CI of the median, assumed symmetric on the log scale:
#   v_i = ((log(upper) - log(lower)) / (2 * 1.96))^2
# Arms without a usable CI (missing, NR upper limit, or non-positive bounds) are dropped.
# Fitted by REML with metafor::rma. tau guides the size of the fixed deviations d_j in
# the simulation (simulation/simulation_plan.md, Sections 1-2).
#
# Run from the project root.
# Input:  data/raw/step3_stratum_arm_variables.xlsx (via load_arm_data() in data_modeling.R)
# Output: results/modeling/model2_logmpfs_reml_coef.csv
#         results/modeling/model2_logmpfs_reml_heterogeneity.csv

required_pkgs <- c("metafor")
missing_pkgs <- setdiff(required_pkgs, rownames(installed.packages()))
if (length(missing_pkgs) > 0) install.packages(missing_pkgs)

library(metafor)
source("scripts/stat_method/data_modeling.R")  # load_arm_data(), DEFAULT_COVARIATES, RES_DIR

Z975 <- qnorm(0.975)

## ---- Data: outcome, sampling variance, complete covariates --------------------

prepare_meta_data <- function(df, covariates = DEFAULT_COVARIATES) {
  d <- df[complete.cases(df[, c("mPFS_months", "mPFS_ci_low", "mPFS_ci_high", "ORR",
                                covariates)]), , drop = FALSE]
  d <- d[d$mPFS_ci_low > 0 & d$mPFS_ci_high > d$mPFS_ci_low, , drop = FALSE]
  d$yi <- log(d$mPFS_months)
  d$vi <- ((log(d$mPFS_ci_high) - log(d$mPFS_ci_low)) / (2 * Z975))^2

  constant <- covariates[vapply(covariates, function(v) length(unique(d[[v]])) < 2, logical(1))]
  if (length(constant) > 0) {
    message("Dropping covariates constant in the fitting data: ", paste(constant, collapse = ", "))
  }
  list(data = d, covariates = setdiff(covariates, constant))
}

## ---- Fit -------------------------------------------------------------------------

fit_meta_logmpfs <- function(df, covariates = DEFAULT_COVARIATES) {
  prep <- prepare_meta_data(df, covariates)
  f <- reformulate(c("ORR", prep$covariates))
  fit <- rma(yi = yi, vi = vi, mods = f, data = prep$data, method = "REML")
  fit$covariates <- prep$covariates
  fit
}

# Coefficient table with median PFS ratios (same columns as tidy_logmpfs)
tidy_meta <- function(fit) {
  est <- drop(coef(fit))
  data.frame(
    term = names(est), estimate = est, std_error = fit$se,
    statistic = fit$zval, p_value = fit$pval,
    mpfs_ratio = exp(est),
    ratio_ci_low = exp(fit$ci.lb),
    ratio_ci_high = exp(fit$ci.ub),
    row.names = NULL
  )
}

# tau with its profile-likelihood 95% CI, plus I^2 and R^2 from metafor
heterogeneity_summary <- function(fit) {
  ci <- confint(fit)$random
  data.frame(
    k_arms = fit$k,
    tau = sqrt(fit$tau2),
    tau_ci_low = ci["tau", "ci.lb"],
    tau_ci_high = ci["tau", "ci.ub"],
    I2_percent = fit$I2,
    R2_percent = fit$R2,
    median_sampling_sd = median(sqrt(fit$vi)),
    QE = fit$QE, QE_df = fit$k - fit$p, QE_p = fit$QEp
  )
}

## ---- Run -----------------------------------------------------------------------

if (sys.nframe() == 0) {
  arm_df <- load_arm_data()
  fit <- fit_meta_logmpfs(arm_df)

  cat(sprintf("\nRandom-effects meta-regression (log mPFS, observed ORR): %d arms\n", fit$k))
  coef_tbl <- tidy_meta(fit)
  print(coef_tbl, digits = 3)
  write.csv(coef_tbl, file.path(RES_DIR, "model2_logmpfs_reml_coef.csv"), row.names = FALSE)

  het <- heterogeneity_summary(fit)
  cat(sprintf("\ntau = %.3f (95%% CI %.3f to %.3f); I^2 = %.1f%%; median sampling SD = %.3f\n",
              het$tau, het$tau_ci_low, het$tau_ci_high, het$I2_percent, het$median_sampling_sd))
  write.csv(het, file.path(RES_DIR, "model2_logmpfs_reml_heterogeneity.csv"), row.names = FALSE)
}
