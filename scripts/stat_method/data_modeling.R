# Arm-level models from statistical_methods.md.
#
# Model 1: logistic models for ORR, logit(p_i) = alpha_0 + alpha^T x_i
#   1.1 binomial:       Y_i ~ Binomial(n_i, p_i)
#   1.2 quasibinomial:  same mean, Var(Y_i) = phi * n_i p_i (1 - p_i); SEs scaled by sqrt(phi)
#   1.3 beta-binomial:  Y_i | q_i ~ Binomial(n_i, q_i), q_i ~ Beta with mean p_i and
#                       intra-arm correlation rho, so Var(Y_i) = n_i p_i (1 - p_i) [1 + (n_i - 1) rho];
#                       fitted by maximum likelihood (optim)
#   Model 2 uses Model 1.1 for p_hat_i (1.1 and 1.2 give the same point estimates).
#
# Model 2: log-linear model for median PFS
#   log m_i = theta_0 + theta_p * p_i + theta^T x_i + eps_i,  eps_i ~ N(0, sigma^2 / n_i)
#   fitted by least squares weighted by n_i. exp(theta_k) is the ratio of median PFS.
#   p_i is either
#     "observed":  the observed ORR_i
#     "estimated": p_hat_i from Model 1 (two-stage); SEs by bootstrap
#
# Covariates are the six EDA covariates, derived as in EDA.R: median age and the
# proportions female, ever-smoker (among known smoking status), ECOG 0, squamous,
# and stage IV (among known stage I-IV); plus the first_line and maintenance
# indicators (maintenance arms also have first_line = 1), and the
# 0/1 MOA components moa_* (all 0 = no active drug) and biomarker_matched (1 = the
# population was selected on a validated predictive biomarker for a drug in the
# regimen), from add_derived_variables.R.
# Rows missing any covariate or the
# outcome are dropped (complete cases).
#
# Input:  data/raw/step3_stratum_arm_variables.xlsx (sheet "claude_collected")
# Output: results/modeling/model1_1_binomial_coef.csv
#         results/modeling/model1_2_quasibinomial_coef.csv
#         results/modeling/model1_3_betabinomial_coef.csv
#         results/modeling/model2_logmpfs_observed_coef.csv
#         results/modeling/model2_logmpfs_estimated_coef.csv

required_pkgs <- c("readxl", "dplyr")
missing_pkgs <- setdiff(required_pkgs, rownames(installed.packages()))
if (length(missing_pkgs) > 0) install.packages(missing_pkgs)

library(readxl)
library(dplyr)

DATA_IN <- "data/raw/step3_stratum_arm_variables.xlsx"
SHEET <- "claude_collected"
RES_DIR <- "results/modeling"

dir.create(RES_DIR, recursive = TRUE, showWarnings = FALSE)

## ---- Covariates (as in EDA.R) --------------------------------------------

MOA_COLS <- c("moa_chemo", "moa_immune_checkpoint", "moa_immune_other", "moa_antiangio",
              "moa_targeted", "moa_other")

DEFAULT_COVARIATES <- c("median_age", "female_prop", "tobacco_ever_prop", "ECOG_0_prop",
                        "squamous_prop", "stage_IV_prop", "first_line", "maintenance", MOA_COLS,
                        "biomarker_matched")

STAGE_COLS <- c("stage_I_II", "stage_IIIA", "stage_IIIB", "stage_IIIB_wet", "stage_IIIC",
                "stage_IV", "stage_recurrent", "stage_Unknown")

# Proportion of the arm; NA when the numerator was not reported
prop_of_n <- function(count, n) ifelse(is.na(n) | n <= 0, NA_real_, count / n)

## ---- Load and derive covariates ----------------------------------------------

load_arm_data <- function(path = DATA_IN, sheet = SHEET) {
  read_excel(path, sheet = sheet) %>%
    filter(!grepl("NOT NSCLC", notes)) %>%
    filter(!is.na(arm_sample_size), arm_sample_size > 0) %>%
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
      # Stage IV among patients with known I-IV stage; IIIB_wet is a subset of IIIB.
      # Arms reporting any stage count unreported stage categories as 0.
      stage_reported = if_any(all_of(STAGE_COLS), ~ !is.na(.x)),
      stage_I_II_n = coalesce(stage_I_II, 0),
      stage_III_n = coalesce(stage_IIIA, 0) + coalesce(stage_IIIB, 0) + coalesce(stage_IIIC, 0),
      stage_IV_n = coalesce(stage_IV, 0),
      stage_known = ifelse(stage_reported, stage_I_II_n + stage_III_n + stage_IV_n, NA_real_),
      stage_IV_prop = prop_of_n(stage_IV_n, stage_known),
      # Responders, rounded because ORR is reported as a rounded proportion
      responders = round(ORR * arm_sample_size)
    )
}

# Complete cases on the needed columns; drop covariates constant in that subset
prepare_model_data <- function(df, covariates, extra_cols) {
  d <- df[complete.cases(df[, c(extra_cols, covariates)]), , drop = FALSE]
  constant <- covariates[vapply(covariates, function(v) length(unique(d[[v]])) < 2, logical(1))]
  if (length(constant) > 0) {
    message("Dropping covariates constant in the fitting data: ", paste(constant, collapse = ", "))
  }
  list(data = d, covariates = setdiff(covariates, constant))
}

## ---- Model 1: logistic model for ORR ------------------------------------------

# family: "binomial" (Model 1.1) or "quasibinomial" (Model 1.2)
fit_logistic_orr <- function(df, covariates = DEFAULT_COVARIATES,
                             family = c("binomial", "quasibinomial")) {
  family <- match.arg(family)
  prep <- prepare_model_data(df, covariates, c("responders", "arm_sample_size"))
  f <- reformulate(prep$covariates, response = "cbind(responders, arm_sample_size - responders)")
  fit <- glm(f, family = get(family)(link = "logit"), data = prep$data)
  fit$covariates <- prep$covariates
  fit
}

# Pearson chi-square / residual df; about 1 when the binomial variance holds
dispersion_ratio <- function(fit) {
  sum(residuals(fit, type = "pearson")^2) / df.residual(fit)
}

# Model 1.3: beta-binomial with logit mean, by maximum likelihood.
# Beta(a_i, b_i) with a_i = p_i s, b_i = (1 - p_i) s; rho = 1 / (1 + s).
# Parameters: alpha (logit scale) and log s. Starts from the binomial fit.
fit_betabinomial_orr <- function(df, covariates = DEFAULT_COVARIATES) {
  start_fit <- fit_logistic_orr(df, covariates)
  d <- start_fit$data
  X <- model.matrix(start_fit)
  X <- X[, !is.na(coef(start_fit)), drop = FALSE]  # drop aliased columns
  y <- d$responders
  n <- d$arm_sample_size

  negloglik <- function(par) {
    p <- plogis(drop(X %*% par[-length(par)]))
    s <- exp(par[length(par)])
    -sum(lchoose(n, y) + lbeta(y + p * s, n - y + (1 - p) * s) - lbeta(p * s, (1 - p) * s))
  }
  start <- c(coef(start_fit)[colnames(X)], log_s = log(50))
  opt <- optim(start, negloglik, method = "BFGS", control = list(maxit = 1000))
  if (opt$convergence != 0) warning("Beta-binomial optim did not converge (code ", opt$convergence, ")")
  vc <- solve(optimHess(opt$par, negloglik))
  k <- length(opt$par)
  list(coef = opt$par[-k], vcov = vc[-k, -k, drop = FALSE],
       rho = 1 / (1 + exp(opt$par[k])), logLik = -opt$value, nobs = nrow(d),
       covariates = start_fit$covariates)
}

# Coefficient table with odds ratios; fit is a glm, or est and vc are given
tidy_logistic <- function(fit = NULL, est = coef(fit),
                          vc = vcov(fit, complete = TRUE)) {
  se <- sqrt(diag(vc))
  z <- est / se
  data.frame(
    term = names(est), estimate = est, std_error = se,
    z_value = z, p_value = 2 * pnorm(-abs(z)),
    odds_ratio = exp(est),
    or_ci_low = exp(est - qnorm(0.975) * se),
    or_ci_high = exp(est + qnorm(0.975) * se),
    row.names = NULL
  )
}

## ---- Model 2: log-linear model for median PFS ---------------------------------

fit_logmpfs_once <- function(d, covariates) {
  d$log_mpfs <- log(d$mPFS_months)
  lm(reformulate(c("p", covariates), response = "log_mpfs"),
     data = d, weights = arm_sample_size)
}

# p_source: "observed"  plugs in the observed ORR_i
#           "estimated" plugs in p_hat_i from Model 1 (two-stage), bootstrap SEs
fit_logmpfs <- function(df, covariates = DEFAULT_COVARIATES,
                        p_source = c("observed", "estimated"),
                        n_boot = 1000, seed = 2026) {
  p_source <- match.arg(p_source)

  if (p_source == "observed") {
    prep <- prepare_model_data(df, covariates, c("mPFS_months", "ORR", "arm_sample_size"))
    d <- prep$data
    d$p <- d$ORR
    fit <- fit_logmpfs_once(d, prep$covariates)
    est <- coef(fit)
    se <- sqrt(diag(vcov(fit, complete = TRUE)))
    return(list(fit = fit, p_source = p_source,
                coef = tidy_logmpfs(est, se, df_resid = fit$df.residual)))
  }

  # Two-stage: Model 1 needs ORR, Model 2 needs mPFS. Arms missing ORR still
  # get p_hat_i, so Model 2 can use them.
  prep <- prepare_model_data(df, covariates, c("mPFS_months", "arm_sample_size"))
  covs <- prep$covariates
  d2 <- prep$data

  two_stage <- function(orr_rows, pfs_rows) {
    m1 <- fit_logistic_orr(orr_rows, covs)
    pfs_rows$p <- predict(m1, newdata = pfs_rows, type = "response")
    coef(fit_logmpfs_once(pfs_rows, m1$covariates))
  }

  orr_df <- df[!is.na(df$responders), , drop = FALSE]
  m1 <- fit_logistic_orr(orr_df, covs)
  d2$p <- predict(m1, newdata = d2, type = "response")
  fit <- fit_logmpfs_once(d2, m1$covariates)
  point <- coef(fit)

  # Nonparametric bootstrap over arms: resample, refit both stages
  set.seed(seed)
  boot <- matrix(NA_real_, n_boot, length(point), dimnames = list(NULL, names(point)))
  for (b in seq_len(n_boot)) {
    bs <- df[sample.int(nrow(df), replace = TRUE), , drop = FALSE]
    bs_orr <- bs[!is.na(bs$responders), , drop = FALSE]
    bs_pfs <- bs[complete.cases(bs[, c("mPFS_months", "arm_sample_size", covs)]), , drop = FALSE]
    res <- tryCatch(suppressWarnings(suppressMessages(two_stage(bs_orr, bs_pfs))),
                    error = function(e) NULL)
    if (!is.null(res)) boot[b, names(res)] <- res
  }
  n_ok <- sum(complete.cases(boot[, !is.na(point), drop = FALSE]))
  if (n_ok < n_boot) message(sprintf("Bootstrap: %d of %d replicates estimated every coefficient (SEs use the available ones)", n_ok, n_boot))

  se <- apply(boot, 2, sd, na.rm = TRUE)
  ci <- apply(boot, 2, quantile, probs = c(0.025, 0.975), na.rm = TRUE)
  coef_tbl <- tidy_logmpfs(point, se, df_resid = NULL)
  coef_tbl$boot_ci_low <- ci[1, ]
  coef_tbl$boot_ci_high <- ci[2, ]
  coef_tbl$ratio_boot_ci_low <- exp(ci[1, ])
  coef_tbl$ratio_boot_ci_high <- exp(ci[2, ])
  list(fit = fit, p_source = p_source, coef = coef_tbl, boot = boot)
}

# Coefficient table with median PFS ratios; normal-theory p-values when df_resid is NULL
tidy_logmpfs <- function(est, se, df_resid) {
  stat <- est / se
  crit <- if (is.null(df_resid)) qnorm(0.975) else qt(0.975, df_resid)
  p <- if (is.null(df_resid)) 2 * pnorm(-abs(stat)) else 2 * pt(-abs(stat), df_resid)
  data.frame(
    term = names(est), estimate = est, std_error = se,
    statistic = stat, p_value = p,
    mpfs_ratio = exp(est),
    ratio_ci_low = exp(est - crit * se),
    ratio_ci_high = exp(est + crit * se),
    row.names = NULL
  )
}

## ---- Run -----------------------------------------------------------------------

if (sys.nframe() == 0) {
  arm_df <- load_arm_data()
  cat(sprintf("Arms loaded: %d\n", nrow(arm_df)))

  m1_1 <- fit_logistic_orr(arm_df, family = "binomial")
  cat(sprintf("\nModel 1.1 (binomial, ORR): %d arms; Pearson X2/df = %.2f\n",
              nobs(m1_1), dispersion_ratio(m1_1)))
  m1_1_tbl <- tidy_logistic(m1_1)
  print(m1_1_tbl, digits = 3)
  write.csv(m1_1_tbl, file.path(RES_DIR, "model1_1_binomial_coef.csv"), row.names = FALSE)

  m1_2 <- fit_logistic_orr(arm_df, family = "quasibinomial")
  cat(sprintf("\nModel 1.2 (quasibinomial, ORR): %d arms; dispersion phi = %.2f\n",
              nobs(m1_2), summary(m1_2)$dispersion))
  m1_2_tbl <- tidy_logistic(m1_2)
  print(m1_2_tbl, digits = 3)
  write.csv(m1_2_tbl, file.path(RES_DIR, "model1_2_quasibinomial_coef.csv"), row.names = FALSE)

  m1_3 <- fit_betabinomial_orr(arm_df)
  cat(sprintf("\nModel 1.3 (beta-binomial, ORR): %d arms; rho = %.3f; logLik = %.1f (binomial %.1f)\n",
              m1_3$nobs, m1_3$rho, m1_3$logLik, as.numeric(logLik(m1_1))))
  m1_3_tbl <- tidy_logistic(est = m1_3$coef, vc = m1_3$vcov)
  print(m1_3_tbl, digits = 3)
  write.csv(m1_3_tbl, file.path(RES_DIR, "model1_3_betabinomial_coef.csv"), row.names = FALSE)

  m2_obs <- fit_logmpfs(arm_df, p_source = "observed")
  cat(sprintf("\nModel 2 (log mPFS, observed ORR): %d arms\n", nobs(m2_obs$fit)))
  print(m2_obs$coef, digits = 3)
  write.csv(m2_obs$coef, file.path(RES_DIR, "model2_logmpfs_observed_coef.csv"), row.names = FALSE)

  m2_est <- fit_logmpfs(arm_df, p_source = "estimated", n_boot = 1000)
  cat(sprintf("\nModel 2 (log mPFS, estimated p): %d arms\n", nobs(m2_est$fit)))
  print(m2_est$coef, digits = 3)
  write.csv(m2_est$coef, file.path(RES_DIR, "model2_logmpfs_estimated_coef.csv"), row.names = FALSE)
}
