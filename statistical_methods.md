# Statistical Methods

The unit of analysis is one trial arm (or one stratum of an arm), indexed by $i = 1, \dots, N$.
The covariates are the six baseline characteristics used in the EDA, plus line of therapy,
the mechanism of action (MOA) of the regimen, and whether the population is biomarker-matched to
the regimen. Proportions use the arm size $n_i$ as denominator,
except smoking and stage, which use only patients with known status.

| Covariate | Symbol | Definition (data columns) |
|---|---|---|
| Sample size | $n_i$ | `arm_sample_size` (weight, not a covariate) |
| Median age | $\text{age}_i$ | `median_age` (years) |
| Female | $F_i$ | `female_count` / $n_i$ |
| Ever-smoker | $T_i$ | ever / (ever + never); ever = `Tobacco_Ever`, or `Tobacco_Current` + `Tobacco_Former` |
| ECOG 0 | $E_i$ | `ECOG_0` / $n_i$ |
| Squamous | $S_i$ | `squamous_count` / $n_i$ |
| Stage IV | $G_i$ | `stage_IV` / (`stage_I_II` + `stage_IIIA` + `stage_IIIB` + `stage_IIIC` + `stage_IV`) |
| First-line | $L_i$ | `first_line` (1 = first-line, incl. maintenance; 0 = pretreated) |
| Matched biomarker | $B_i$ | `biomarker_matched` (1 = population selected on a validated predictive biomarker for a drug in the regimen, e.g. EGFR mutation + EGFR TKI, ALK + ALK inhibitor, PD-L1 or TMB-high + checkpoint inhibitor; 0 otherwise) |
| MOA components | $M_{i,k}$ | `moa_chemo`, `moa_immune_checkpoint`, `moa_immune_other`, `moa_antiangio`, `moa_targeted`, `moa_other` (0/1) |

The MOA indicators are not mutually exclusive: a combination regimen has several set to 1.
All $M_{i,k} = 0$ (no active drug) is the reference. Let
$\mathcal{M} = (\text{chemo},\ \text{ICI},\ \text{other immune},\ \text{anti-angio},\ \text{targeted},\ \text{other})$.

$\mathbf{x}_i$ is the covariate vector of arm $i$ (the intercept is kept separate):

$$
\mathbf{x}_i = \big(\text{age}_i,\ F_i,\ T_i,\ E_i,\ S_i,\ G_i,\ L_i,\ (M_{i,k})_{k \in \mathcal{M}},\ B_i\big)^\top
$$

Arms missing any covariate are excluded (complete cases).

## Model 1: Logistic models for objective response rate

Let $Y_i$ be the number of responders in arm $i$, so that $\text{ORR}_i = Y_i / n_i$.
All three versions share the same mean model and differ only in the variance of $Y_i$.

### Model 1.1: Binomial

$$
Y_i \sim \text{Binomial}(n_i, p_i)
$$

$$
\mathrm{logit}(p_i) = \log\frac{p_i}{1 - p_i}
= \alpha_0 + \boldsymbol\alpha^\top \mathbf{x}_i
$$

Written out in full:

$$
\begin{aligned}
\mathrm{logit}(p_i) = \alpha_0
&+ \alpha_{\text{age}}\text{age}_i + \alpha_F F_i + \alpha_T T_i + \alpha_E E_i + \alpha_S S_i + \alpha_G G_i \\
&+ \alpha_L L_i + \sum_{k \in \mathcal{M}} \alpha_{M,k} M_{i,k} + \alpha_B B_i
\end{aligned}
$$

Here $p_i$ is the true response probability of arm $i$. $\exp(\alpha_k)$ is the odds ratio
of response per unit increase in covariate $k$, holding the other covariates fixed.

**Likelihood.** With arms independent and $\lambda_i = \alpha_0 + \boldsymbol\alpha^\top \mathbf{x}_i$,

$$
L(\alpha_0, \boldsymbol\alpha) = \prod_{i=1}^{N} \binom{n_i}{Y_i}\, p_i^{Y_i} (1-p_i)^{n_i - Y_i},
\qquad p_i = \frac{1}{1 + e^{-\lambda_i}}
$$

$$
\ell(\alpha_0, \boldsymbol\alpha) = \sum_{i=1}^{N} \Big[\, Y_i \lambda_i - n_i \log\!\big(1 + e^{\lambda_i}\big) \Big] + \text{const}
$$

Arm size $n_i$ enters directly: arm $i$ contributes the information of $n_i$ Bernoulli trials.
Only $\text{ORR}_i$ and $n_i$ are reported, so $Y_i = \mathrm{round}(\text{ORR}_i \cdot n_i)$.

The binomial assumes $\mathrm{Var}(Y_i) = n_i p_i(1-p_i)$: all arms with the same covariates share
one response probability. Arms from different trials vary more than that (overdispersion),
checked by the Pearson ratio $\hat\phi = \frac{1}{N - q}\sum_i \frac{(Y_i - n_i\hat p_i)^2}{n_i \hat p_i(1-\hat p_i)}$,
where $q$ is the number of coefficients. $\hat\phi \approx 1$ when the binomial variance holds;
$\hat\phi > 1$ means the Model 1.1 standard errors are too small by about $\sqrt{\hat\phi}$.

### Model 1.2: Quasibinomial

Same mean model, with the variance inflated by a common factor $\phi$:

$$
\mathbb{E}(Y_i) = n_i p_i, \qquad \mathrm{Var}(Y_i) = \phi\, n_i p_i(1-p_i)
$$

There is no full likelihood. $\boldsymbol\alpha$ solves the same estimating equations as
Model 1.1, so the point estimates are identical; $\phi$ is estimated by $\hat\phi$ above and
every standard error is multiplied by $\sqrt{\hat\phi}$. Every arm's variance is scaled by the
same factor, so relative weights between arms are unchanged.

### Model 1.3: Beta-binomial

The response probability of arm $i$ varies around $p_i$:

$$
Y_i \mid q_i \sim \text{Binomial}(n_i, q_i), \qquad
q_i \sim \text{Beta}\big(p_i s,\ (1-p_i) s\big), \qquad
\mathrm{logit}(p_i) = \alpha_0 + \boldsymbol\alpha^\top \mathbf{x}_i
$$

so $\mathbb{E}(q_i) = p_i$ and, with intra-arm correlation $\rho = 1/(1+s)$,

$$
\mathrm{Var}(Y_i) = n_i p_i(1-p_i)\,\big[1 + (n_i - 1)\rho\big]
$$

$\rho = 0$ gives Model 1.1. Integrating out $q_i$ gives the likelihood

$$
L(\alpha_0, \boldsymbol\alpha, s) = \prod_{i=1}^{N} \binom{n_i}{Y_i}
\frac{B\big(Y_i + p_i s,\ n_i - Y_i + (1-p_i) s\big)}{B\big(p_i s,\ (1-p_i) s\big)}
$$

where $B$ is the beta function; it is maximized numerically over $(\alpha_0, \boldsymbol\alpha, \log s)$,
with standard errors from the inverse Hessian. Unlike Model 1.2, the extra variance grows with
$n_i$, so large arms get relatively less weight than under the binomial.

## Model 2: Log-linear model for median progression-free survival

Let $m_i$ be the reported median PFS (months) of arm $i$.

$$
\log m_i = \theta_0 + \theta_pp_i + \boldsymbol\theta^\top \mathbf{x}_i + \varepsilon_i,
\qquad \varepsilon_i \sim N\!\left(0,\ \sigma^2 / n_i\right)
$$

$\boldsymbol\theta$ has one coefficient per entry of $\mathbf{x}_i$, as in Model 1.
The model is fitted by weighted least squares with weights $n_i$, because larger arms estimate
their median more precisely. $\exp(\theta_k)$ is the ratio of median PFS per unit increase in
covariate $k$, holding the other covariates fixed. $p_i$ is handled as described under Model 3.

**Likelihood.** With arms independent and $\mu_i = \theta_0 + \theta_p p_i + \boldsymbol\theta^\top \mathbf{x}_i$,

$$
L(\theta_0, \theta_p, \boldsymbol\theta, \sigma^2) = \prod_{i=1}^{N} \sqrt{\frac{n_i}{2\pi\sigma^2}}
\exp\!\left(-\frac{n_i(\log m_i - \mu_i)^2}{2\sigma^2}\right)
$$

$$
\ell = -\frac{1}{2\sigma^2}\sum_{i=1}^{N} n_i(\log m_i - \mu_i)^2 - \frac{N}{2}\log\sigma^2 + \text{const}
$$

Maximizing over $\theta$ is weighted least squares with weights $n_i$; $\sigma^2$ is estimated
from the weighted residuals.

This model only needs the median, which almost every arm reports. It links to Model 3 as follows.
Under a Weibull baseline, $\log H_0(t) = \beta_0 + k\log t$, and at the median $H_i(m_i) = \log 2$. Model 3 then gives

$$
\log m_i = \frac{\log\log 2 - \beta_0 - \beta_pp_i - \boldsymbol\beta^\top \mathbf{x}_i}{k}
\quad\Longrightarrow\quad
\theta_j = -\beta_j / k
$$

So Model 2 is Model 3 evaluated at the median. Covariates that lengthen median PFS have
$\theta_k > 0$ and hazard ratio $\exp(\beta_k) < 1$. The shape $k$ cannot be estimated from
medians alone. Converting $\theta$ to hazard ratios therefore needs an assumed $k$
($k = 1$ is the exponential model), or KM data as in Model 3.

## Model 3: Log-hazard model for progression-free survival

Survival quantities, where $S_i(t)$ is the PFS survival function of arm $i$:

$$
H_i(t) = -\log S_i(t)
\quad\Longrightarrow\quad
\log H_i(t) = \log(-\log S_i(t))
$$

So $\log H_i(t)$ is the complementary log-log of $S_i(t)$. $S_i(t)$ comes from the arm's
Kaplan–Meier PFS curve. Assuming proportional hazards across arms:

$$
\log H_i(t) = \log H_0(t) + \beta_pp_i + \boldsymbol\beta^\top \mathbf{x}_i
$$

$H_0(t)$ is the baseline cumulative hazard, shared by all arms. It absorbs the intercept.
$\boldsymbol\beta$ has one coefficient per entry of $\mathbf{x}_i$, as in Model 1.
$\exp(\beta_k)$ is the hazard ratio of progression or death per unit increase in covariate $k$.

There are two ways to specify $H_0(t)$:

- **Nonparametric:** reconstruct patient-level data from each Kaplan–Meier curve
  (e.g. the Guyot algorithm), then fit a Cox model with the arm-level covariates.
- **Parametric:** for example Weibull, $\log H_0(t) = \beta_0 + k \log t$.

Proportional hazards means the curves of $\log H_i(t)$ against $\log t$ are parallel across arms.
Check this on the Kaplan–Meier curves.

### Handling $p_i$ in Models 2 and 3

$p_i$ is not observed. The options are:

1. **Plug in the observed $\text{ORR}_i$.** This is simple, but measurement error in ORR
   biases $\theta_p$ and $\beta_p$ toward zero.
2. **Two-stage.** Plug in $\hat p_i$ fitted from Model 1. The standard errors need a bootstrap.
3. **Joint model** (Bayesian, recommended). Fit Model 1 with Model 2 or 3, so that the same
   latent $p_i$ enters both likelihoods and its uncertainty carries through to $\theta_p$ or $\beta_p$.

## Notes

- **Identifiability:** each covariate is a single proportion or indicator, so no reference
  category needs to be dropped. Smoking and stage use known-status denominators, so the
  unknown share of an arm does not enter the covariate.

- **Weights:** arms differ a lot in size. The binomial likelihood in Model 1 already
  accounts for $n_i$. Model 2 uses weights $n_i$. In Model 3, arm size is accounted for automatically
  when the model is fitted on reconstructed patient-level data.
