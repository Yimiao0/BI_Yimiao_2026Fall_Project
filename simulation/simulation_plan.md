# Simulation Plan (draft for discussion)

Goal: re-run the Zhong et al. adaptive design (interim arm selection + sample size re-estimation
using ORR as surrogate information) with patient-level data whose ORR–PFS link comes from our
NSCLC trial-arm data, instead of drawing the predicted log-rank statistic directly from a normal
distribution.

## 0. What we are replacing

In `Chengxue_code/Rcodes/funcs.R` (`sim.trial`, lines 241–259):

```r
riskdiff.hat = riskdiff + phi                       # deterministic, no ORR data simulated
zhrprd = rnorm(1, log(lambda)*sqrt(m1/4) + corr*(riskdiff.hat - riskdiff), sqrt(1 - corr^2))
```

That is,

$$
Z_{\text{pred}} \sim N\!\left(\log(\lambda)\sqrt{m_1/4} + \rho\,(\widehat{\Delta p} - \Delta p),\; 1 - \rho^2\right),
$$

where $\lambda = \text{median}_c / \text{median}_t$ is the treatment-vs-control hazard ratio
(exponential PFS), $m_1$ is the number of PFS events at the interim, $\rho$ is `corr`, and
$\widehat{\Delta p} = \Delta p + \phi$.

Problems:
- No patient has a response. The "observed" risk difference is the truth plus a fixed bias $\phi$.
- $Z_{\text{pred}}$ is drawn independently of the simulated PFS data. Its link to the observed
  $Z_1$ and to the final test comes only through the true HR.
- $\rho$ is a free knob with no empirical anchor.

We want ORR and PFS generated jointly for each patient, an interim ORR estimate that has real
sampling noise, and a prediction model taken from historical data.

## 1. Real-data relationship that drives the simulation

We use the fitted arm-level model, `scripts/stat_method/data_modeling.R`, Model 2 with
observed ORR (80 complete-case arms):

$$
\log \text{mPFS} = \theta_0 + \theta_p\, p + \boldsymbol{\theta}^\top \mathbf{x} + \varepsilon
$$

- $\theta_p \approx 1.34$ (SE 0.22): an ORR that is 10 percentage points higher (e.g. 0.20 →
  0.30) goes with a median PFS about $e^{1.34 \times 0.10} \approx 1.14$ times as long (14% longer).
- Residual SD of $\varepsilon \approx 2.07/\sqrt{n}$. The model is weighted least squares with
  weights $n_i$, i.e. $\text{Var}(\varepsilon_i) = \sigma^2 / n_i$, and the fit gives
  $\hat\sigma \approx 2.07$ (`summary(fit)$sigma`). For an arm with $n = 100$ the SD is
  $\approx 0.21$ on the log scale.

**Implied treatment effect.** Both arms of a randomized trial share the same covariates
$\mathbf{x}$, so $\mathbf{x}$ cancels:

$$
\log \text{mPFS}_t - \log \text{mPFS}_c
= \theta_p (p_t - p_c) + \boldsymbol{\theta}_{\text{MOA}}^\top (\text{MOA}_t - \text{MOA}_c)
$$

This one equation is used for three things:
- **Control arm:** choose $\mathbf{x}$ and $p_c$ for a trial setting, then compute
  $\text{mPFS}_c$ from the model. Check it against the observed medians. A setting is the line
  of therapy (`first_line` covariate) plus its standard-of-care control: e.g. a first-line (1L)
  trial with platinum chemo as control, or a second-line (2L, after progression on 1L) trial
  with docetaxel as control. Each setting is a separate set of simulations.
- **True treatment effect:** set $p_t$ and the treatment's MOA, which gives $\text{mPFS}_t$.
- **Interim prediction:** plug the ORR difference *observed* at the interim, $\widehat{\Delta p}$, into the same equation (with fitted $\hat\theta_p$) to get a predicted PFS effect (Section 5).

**Assumption.** The ORR–PFS slope seen across arms (after covariate adjustment) also holds
between arms of the same randomized trial.

How far the truth departs from the ORR prediction is instead set by a **fixed deviation $d_j$**
in each scenario (Section 2). Its realistic size can be guided by the between-arm heterogeneity
$\tau \approx 0.17$ on the log mPFS scale. That figure comes from a random-effects
meta-regression using each arm's reported mPFS CI (52 arms), so sampling noise is removed.
$d_j$ plays the role of Zhong's $\phi$ (also a fixed offset).

## 2. Scenarios (true parameters)

Use the Zhong layout: control + 3 treatment arms, select 1 arm at the interim.

Per arm $j$:

$$
p_j = p_c + \Delta p_j, \qquad
\log \text{mPFS}_j = \log \text{mPFS}_c + \theta_p \Delta p_j
+ \boldsymbol{\theta}_{\text{MOA}}^\top \Delta\text{MOA}_j + d_j
$$

The second equation is the true PFS effect. $d_j$ is a fixed deviation from the ORR prediction:
- $d_j = 0$: on the model, so ORR predicts PFS correctly.
- $d_j < 0$: PFS is worse than ORR predicts (ORR is optimistic).
- $d_j > 0$: PFS is better than ORR predicts.

| Scenario | $\Delta p$ (3 arms) | PFS effect | Purpose |
|---|---|---|---|
| S0 global null | 0, 0, 0 | none | type I error |
| S0' surrogate-misleading null | e.g. .10, .15, .20 | none ($\text{mPFS}_j = \text{mPFS}_c$) | type I error and wasted resources when ORR looks good |
| S1 consistent | e.g. .05, .10, .15 | model, $d_j = 0$ | best case for the surrogate |
| S2 imperfect surrogate | same | model + $d_j \in \{-2\tau, -\tau, +\tau\}$ | main sensitivity |
| S3 discordant | .05, .10, .20 | true HR set directly; ORR ranks the arms in reverse order (details below) | wrong-arm selection |
| S4 PFS gain without ORR | 0 | $\text{mPFS}_j > \text{mPFS}_c$ (e.g. maintenance, anti-angiogenic) | surrogate hurts |

Control settings: at least two from Section 1, simulated separately, e.g. a 2L trial with docetaxel
control ($p_c \approx 0.10$, $\text{mPFS}_c \approx 3$ mo) and a 1L trial with platinum-chemo
control ($p_c \approx 0.30$, $\text{mPFS}_c \approx 5.5$ mo). Medians can be cross-checked with
`get.medians()`.

**S3 details** (1L setting: $p_c = 0.30$, $\text{mPFS}_c = 5.5$ mo; $\theta_p = 1.34$).
The arm with the biggest ORR gain has the smallest PFS gain, and the reverse. The correct
selection is arm 1, but ORR points to arm 3. HR is under exponential PFS (mPFS$_c$ / mPFS$_j$).

| Arm | $\Delta p_j$ | $p_j$ | Predicted from ORR: mPFS (HR) | **S3a strong**: true mPFS (HR), $d_j$ | **S3b mild**: true mPFS (HR), $d_j$ |
|---|---|---|---|---|---|
| 1 | 0.05 | 0.35 | 5.88 (0.94) | 7.86 (0.70), +0.29 | 7.33 (0.75), +0.22 |
| 2 | 0.10 | 0.40 | 6.29 (0.87) | 6.47 (0.85), +0.03 | 6.88 (0.80), +0.09 |
| 3 | 0.20 | 0.50 | 7.19 (0.76) | 5.50 (1.00), −0.27 | 6.47 (0.85), −0.11 |

- S3a: arm 3 has no PFS benefit at all, despite the largest ORR gain.
- S3b: all arms work, with only a mild reversal. $|d_j| \le 0.22$, i.e. up to about $1.3\tau$.
- $d_j = \log(\text{true mPFS}_j / \text{mPFS}_c) - \theta_p \Delta p_j$.

## 3. Patient-level data generation (per trial replicate)

Start with a simple case. Each patient carries only what the design needs: treatment arm,
enrollment time, response, and PFS time. Everything else follows Zhong's `sim.data`.

For patient $i$ in arm $j$:

1. **Arm and enrollment** $a_i$: equal numbers per arm, enrolled uniformly at rate $r$ per month
   (as in `sim.data`; Zhong used 15/month).
2. **Response** $R_i \sim \text{Bernoulli}(p_j)$.
3. **PFS given response** (responder-mixture model):
   - Non-responder ($R_i = 0$): $\text{PFS}_i \sim \text{Exp}(h_j)$.
   - Responder ($R_i = 1$): $\text{PFS}_i \sim \text{Exp}(\kappa h_j)$.
   - $\kappa < 1$ is the hazard ratio for responders vs. non-responders.
   - **Solve for $h_j$** so that the mixture median equals the target $\text{mPFS}_j$ from
     Section 2, i.e. $p_j e^{-\kappa h_j \text{mPFS}_j} + (1 - p_j) e^{-h_j \text{mPFS}_j} = 0.5$
     (one-dimensional root finding with `uniroot`).
4. **Censoring**: administrative only. At each analysis date, patients without progression are
   censored at that date. No dropout (as in Zhong, `lfu = 0`).
5. **ORR at an analysis**: the observed response rate among patients enrolled before that date.
   Response is treated as known at enrollment.

Left out of the simple case and possible to add later: response timing (scan schedule),
confirmation of response, dropout, ramp-up accrual, and Weibull PFS.

**Choosing $\kappa$.** $\kappa$ sets how much of the PFS effect runs *through* response:
- Even with $h_j$ held fixed (no direct effect), the mixture alone makes mPFS increase with $p$.
- Implied slope $d \log \text{mPFS} / dp$ for an exponential mixture:

  | $\kappa$ | slope at $p$ = .1 / .3 / .5 |
  |---|---|
  | 0.2 | 1.18 / 1.48 / 1.83 |
  | 0.3 | 0.97 / 1.13 / 1.29 |
  | 0.4 | 0.79 / 0.88 / 0.96 |
  | 0.5 | 0.62 / 0.67 / 0.71 |

- With $\kappa \approx 0.3$ the ORR difference explains roughly all of $\theta_p \approx 1.34$
  ("full mediation").
- With $\kappa$ = 0.4–0.5, the rest of $\theta_p$ comes from a shift in $h_j$ that moves with
  $\Delta p$ (an "associated direct effect").
- $\kappa$ is not identifiable from arm-level data. Treat it as a sensitivity parameter
  (0.3 / 0.5), anchored to published responder vs. non-responder landmark HRs in NSCLC.
- Whatever $\kappa$ is, step 3 forces each arm's median to equal $\text{mPFS}_j$. $\kappa$ only
  changes how PFS is shared between responders and non-responders.

Other notes:
- PH does not hold exactly under the mixture, which is realistic.
- Report the true effect as the median ratio and as the average HR from a large-sample Cox fit.

## 4. Interim analysis

- Timing: $m_1$ PFS events, using the same rule as Zhong (`cond = 'min'/'max'`).
- PFS: Cox or log-rank on data truncated at the interim gives $Z_{1,j}$ (as in the current code).
- ORR: $\widehat{\Delta p}_j = \hat p_j - \hat p_c$ among patients enrolled before the interim,
  with standard error $\text{SE}_j$.

## 5. Surrogate prediction and conditional power

Prediction uses the fitted arm-level model with its **fitted** estimates. The simulated truth
may differ from the fit, which is the point of S0'–S4.

- Predicted log median ratio:
  $\hat\mu_j = \hat\theta_p \widehat{\Delta p}_j$ (+ $\hat{\boldsymbol{\theta}}_{\text{MOA}}^\top \Delta\text{MOA}_j$ if MOA differs).
- Predicted log HR $\approx -\hat\mu_j$ (exponential approximation, or a mapping calibrated by
  simulation).
- Prediction variance:
  $V_j = \hat\theta_p^2\, \text{SE}_j^2 + \widehat{\Delta p}_j^2\, \text{Var}(\hat\theta_p)$.
- $Z_{\text{pred},j} = (\text{predicted log HR}) \cdot \sqrt{m_1/4}$, with an SD that follows
  from $V_j$. This replaces `zhrprd`; its spread is now driven by data, not by $\rho$.

Then use the existing `Z1toCP1` / `find_tstar` with the `wt=1` or `wt=2` combination of $Z_1$
and $Z_{\text{pred}}$. Option to discuss: weight $Z_{\text{pred}}$ by its precision ($1/V_j$
relative to the information in $Z_1$) rather than by the fixed $t$.

## 6. Continue the trial

Stage 2 keeps the existing structure:
- Zones (Fut / Unfav / Prom / Fav).
- Event re-estimation $m_2^*$.
- Stage-2 patients generated by the same Section 3 mechanism.
- Final analysis: Simes + CHW combination test on **PFS only**.
- The non-adaptive comparator (`sim.nadapt`) uses the same patients.

## 7. Designs compared and metrics

Designs:
- (i) no surrogate (`wt=0`)
- (ii) Zhong naive `zhrprd`
- (iii) real-data surrogate (ours)
- (iv) fixed design

Metrics:
- type I error (S0, S0')
- power
- probability of correct arm selection
- zone probabilities
- $E[\text{events}]$, $E[N]$, study duration
- bias of the final HR estimate

## 8. Validation of the generator (before running designs)

- Simulate many large arms across a grid of $(p, \text{mPFS})$ targets. Check that the simulated
  ORR and KM median recover the targets for each $\kappa$ (checks the $h_j$ solver).
- Simulate ~2,000 two-arm trials with varied $(p_c, \Delta p, n)$. Regress the observed
  $\Delta \log \widehat{\text{mPFS}}$ on $\widehat{\Delta p}$. The slope should come back close
  to $\theta_p$ (allowing for attenuation from noise in $\widehat{\Delta p}$).
- Check that the marginal ORR and mPFS ranges match the EDA (ORR 0–0.83, mPFS 1.6–23 mo).

## 9. Proposed files

```
simulation/
  simulation_plan.md          # this file
  00_load_arm_model.R         # Section 1: theta-hat, vcov, sigma from data_modeling.R -> params/*.rds
  01_generate_patients.R      # Section 3: gen_trial(arms, n, accrual, kappa, ...) + h_j solver
  02_validate_generator.R     # Section 8
  03_design_functions.R       # interim/prediction/CP/stage-2, reusing Chengxue funcs.R
  04_run_scenarios.R          # Section 2 × Section 7 grid
  results/
```

## Open questions for us

1. Does the MOA difference enter the prediction? (In practice it is known at design time.)
2. $\kappa$ values: which literature to anchor them to.
3. Grid for the fixed deviation $d_j$: is $\{-2\tau, -\tau, 0, +\tau\}$ with $\tau \approx 0.17$
   reasonable? (The $\tau$ fit needs to be added as a script.)
4. Is Zhong's 4-arm, select-1 setup the main design, or do we also run a 2-arm SSR-only case?
