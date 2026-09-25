# Statistical Methods

The unit of analysis is one trial arm (or one stratum of an arm), indexed by $i = 1, \dots, N$.
Every category column of a categorical baseline variable is a covariate. Each is a
proportion of the arm: $x_{i,c} = \text{count}_{i,c} / n_i$.

| Variable | Symbol | Categories $c$ (data columns) |
|---|---|---|
| Sample size | $n_i$ | `arm_sample_size` |
| Median age | $\text{age}_i$ | `median_age` (years, continuous) |
| Sex | $F_i$ | `female_count` |
| ECOG | $E_{i,c}$ | `ECOG_0`, `ECOG_1`, `ECOG_0_1`, `ECOG_2`, `ECOG_3`, `ECOG_4`, `ECOG_Unknown` |
| Tobacco use | $T_{i,c}$ | `Tobacco_Never`, `Tobacco_Ever`, `Tobacco_Current`, `Tobacco_Former`, `Tobacco_Unknown` |
| Stage | $G_{i,c}$ | `stage_I_II`, `stage_IIIA`, `stage_IIIB`, `stage_IIIB_wet`, `stage_IIIC`, `stage_IV`, `stage_recurrent`, `stage_Unknown` |
| Histology | $H^{\text{hist}}_{i,c}$ | `squamous_count`, `nonsquamous_count`, `histology_Unknown` |

Category sets used in the sums below:

$$
\begin{aligned}
\mathcal{E} &= \{0,\ 1,\ 0\text{–}1,\ 2,\ 3,\ 4,\ \text{Unk}\} \\
\mathcal{T} &= \{\text{Never},\ \text{Ever},\ \text{Current},\ \text{Former},\ \text{Unk}\} \\
\mathcal{G} &= \{\text{I–II},\ \text{IIIA},\ \text{IIIB},\ \text{IIIB wet},\ \text{IIIC},\ \text{IV},\ \text{Recurrent},\ \text{Unk}\} \\
\mathcal{S} &= \{\text{Squamous},\ \text{Nonsquamous},\ \text{Unk}\}
\end{aligned}
$$

For compactness, write the shared covariate part of both models as

$$
\eta_i(\boldsymbol\gamma) =
\gamma_{\text{age}}\,\text{age}_i + \gamma_F\,F_i
+ \sum_{c \in \mathcal{E}} \gamma_{E,c}\,E_{i,c}
+ \sum_{c \in \mathcal{T}} \gamma_{T,c}\,T_{i,c}
+ \sum_{c \in \mathcal{G}} \gamma_{G,c}\,G_{i,c}
+ \sum_{c \in \mathcal{S}} \gamma_{S,c}\,H^{\text{hist}}_{i,c}
$$

## Model 1: Logistic model for objective response rate

Let $Y_i$ be the number of responders in arm $i$, so that $\text{ORR}_i = Y_i / n_i$.

$$
Y_i \sim \text{Binomial}(n_i,\, p_i)
$$

$$
\operatorname{logit}(p_i) = \log\frac{p_i}{1 - p_i}
= \alpha_0 + \eta_i(\boldsymbol\alpha)
$$

Written out in full:

$$
\begin{aligned}
\operatorname{logit}(p_i) = \alpha_0
&+ \alpha_{\text{age}}\,\text{age}_i + \alpha_F\,F_i \\
&+ \alpha_{E,0}\,E_{i,0} + \alpha_{E,1}\,E_{i,1} + \alpha_{E,0\text{–}1}\,E_{i,0\text{–}1} + \alpha_{E,2}\,E_{i,2} + \alpha_{E,3}\,E_{i,3} + \alpha_{E,4}\,E_{i,4} + \alpha_{E,\text{Unk}}\,E_{i,\text{Unk}} \\
&+ \alpha_{T,\text{Never}}\,T_{i,\text{Never}} + \alpha_{T,\text{Ever}}\,T_{i,\text{Ever}} + \alpha_{T,\text{Current}}\,T_{i,\text{Current}} + \alpha_{T,\text{Former}}\,T_{i,\text{Former}} + \alpha_{T,\text{Unk}}\,T_{i,\text{Unk}} \\
&+ \alpha_{G,\text{I–II}}\,G_{i,\text{I–II}} + \alpha_{G,\text{IIIA}}\,G_{i,\text{IIIA}} + \alpha_{G,\text{IIIB}}\,G_{i,\text{IIIB}} + \alpha_{G,\text{IIIB wet}}\,G_{i,\text{IIIB wet}} \\
&\quad + \alpha_{G,\text{IIIC}}\,G_{i,\text{IIIC}} + \alpha_{G,\text{IV}}\,G_{i,\text{IV}} + \alpha_{G,\text{Rec}}\,G_{i,\text{Rec}} + \alpha_{G,\text{Unk}}\,G_{i,\text{Unk}} \\
&+ \alpha_{S,\text{Sq}}\,H^{\text{hist}}_{i,\text{Sq}} + \alpha_{S,\text{NonSq}}\,H^{\text{hist}}_{i,\text{NonSq}} + \alpha_{S,\text{Unk}}\,H^{\text{hist}}_{i,\text{Unk}}
\end{aligned}
$$

Here $p_i$ is the true response probability of arm $i$. $\exp(\alpha_k)$ is the odds ratio
of response per unit increase in covariate $k$, holding the other covariates fixed.

## Model 2: Log-hazard model for progression-free survival

Survival quantities, where $S_i(t)$ is the PFS survival function of arm $i$:

$$
H_i(t) = -\log S_i(t)
\quad\Longrightarrow\quad
\log H_i(t) = \log\{-\log S_i(t)\}
$$

So $\log H_i(t)$ is the complementary log-log of $S_i(t)$. $S_i(t)$ comes from the arm's
Kaplan–Meier PFS curve. Assuming proportional hazards across arms:

$$
\log H_i(t) = \log H_0(t) + \beta_p\,p_i + \eta_i(\boldsymbol\beta)
$$

$H_0(t)$ is the baseline cumulative hazard, shared by all arms. It absorbs the intercept.
$\eta_i(\boldsymbol\beta)$ has the same terms as the Model 1 expansion above, with each $\alpha$ replaced by $\beta$.
$\exp(\beta_k)$ is the hazard ratio of progression or death per unit increase in covariate $k$.

There are two ways to specify $H_0(t)$:

- **Nonparametric:** reconstruct patient-level data from each Kaplan–Meier curve
  (e.g. the Guyot algorithm), then fit a Cox model with the arm-level covariates.
- **Parametric:** for example Weibull, $\log H_0(t) = \beta_0 + k \log t$.

Proportional hazards means the curves of $\log H_i(t)$ against $\log t$ are parallel across arms.
Check this on the Kaplan–Meier curves.

### Handling $p_i$ in Model 2

$p_i$ is not observed. The options are:

1. **Plug in the observed $\text{ORR}_i$.** This is simple, but measurement error in ORR
   biases $\beta_p$ toward zero.
2. **Two-stage.** Plug in $\hat p_i$ fitted from Model 1. The standard errors need a bootstrap.
3. **Joint model** (Bayesian, recommended). Fit Models 1 and 2 together, so that the same
   latent $p_i$ enters both likelihoods and its uncertainty carries through to $\beta_p$.

## Notes

- **Categories are not all identifiable at once.** Within one variable, the category proportions
  sum to 1 when fully reported, which makes them perfectly collinear with the intercept. Each
  variable therefore needs a reference category that is dropped (for example `Unknown`), or a
  sum-to-zero constraint or shrinkage prior. 

- **Weights:** arms differ a lot in size. The binomial likelihood in Model 1 already
  accounts for $n_i$. In Model 2, arm size is accounted for automatically
  when the model is fitted on reconstructed patient-level data.
