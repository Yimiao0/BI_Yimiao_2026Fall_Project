# NSCLC ORR–PFS Data Collection Workflow

*Project goal: extending Zhong et al. (2022) platform trial design with an empirically fitted ORR–PFS surrogate relationship, positioned relative to Franzese et al. (2026).*

## Key context from Franzese et al. supplement

Franzese et al.'s 114-study dataset was **not** built from ClinicalTrials.gov + manual curve digitization — it came from **Certara's PD1ST (PD-1 Solid Tumors) clinical outcomes database**, a licensed commercial dataset (167 candidates screened down to 114 for the ORR analysis). Their public supplement provides:

- **Table S3**: dataset summary counts by treatment type (studies/arms/strata-arms)
- **Table S4**: fitted ORR model treatment-specific intercepts (coefficients, %RSE, absolute effect) — useful as an *external reference point*, not raw data
- **No** trial-arm-level raw ORR/PFS data, and **no** study list with NCT numbers

**Implications:**
1. You cannot shortcut data collection by reusing "their" dataset — you need to build your own.

## Refined workflow

### Step 1 — Pull candidate trials via the CT.gov API
ClinicalTrials.gov has a public REST API (v2, live since 2024): free, no key required, JSON responses, base endpoint:
```
https://clinicaltrials.gov/api/v2/studies
```
Two stages. **Stage 1** — broad pull with `query.cond=Non-Small Cell Lung Cancer`, `filter.overallStatus=COMPLETED`, `filter.advanced=AREA[StudyType]INTERVENTIONAL` only, so nothing gets dropped by an over-narrow server-side query. **Stage 2** — tabulate the intervention types found across the raw pool, then keep only studies with at least one drug-like type (DRUG / BIOLOGICAL / COMBINATION_PRODUCT / GENETIC). This catches non-drug studies that `INTERVENTIONAL` alone lets through — e.g. NCT05348187, a PCR diagnostic-kit performance study whose only intervention type is DIAGNOSTIC_TEST — without dropping a real drug trial that also lists a companion diagnostic/device. Each result includes NCT ID, arms, phase, sponsor, and sometimes posted summary results.

**StudyType breakdown** (NSCLC + COMPLETED, no other filter — 3,249 total):

| Value | Count |
|---|---|
| INTERVENTIONAL | 2,700 |
| OBSERVATIONAL | 549 |
| EXPANDED_ACCESS | 0 |

**InterventionType breakdown** (NSCLC + COMPLETED + INTERVENTIONAL — Stage 1's 2,700-study pool; a study can have >1 type):

| Value | Count |
|---|---|
| DRUG | 2,212 |
| BIOLOGICAL | 336 |
| RADIATION | 266 |
| OTHER | 260 |
| PROCEDURE | 208 |
| DEVICE | 47 |
| BEHAVIORAL | 41 |
| DIETARY_SUPPLEMENT | 23 |
| DIAGNOSTIC_TEST | 22 |
| GENETIC | 16 |
| COMBINATION_PRODUCT | 12 |

### Step 2 — Link each NCT ID to its primary publication
CT.gov's own "Results" module usually don't have K-M curves. For example, NCT00638937 posts only median of PFS and its 95% CI — with no digitizable curve or risk table anywhere on the record. Use PubMed E-utilities to search:
```
NCT_ID[Secondary Source ID]
```
Most registered-trial publications tag their NCT number in PubMed metadata, so this linkage is largely automatable via `rentrez` (an R package that wraps the PubMed E-utilities API for programmatic search and retrieval).

### Step 3 — Screen publications for usable KM data
Not purely manual: full-text can be pre-filtered by keyword search for "Kaplan-Meier" or "K-M" — a paper that reports a KM analysis in its methods will almost always say so explicitly, so this is a reliable first-pass filter to cut down the candidate pool before deeper screening. From there, a vision-capable LLM can do useful second-pass triage — flagging whether a PFS KM figure and an accompanying risk table are present, and pre-extracting reported ORR from text. Human spot-checking of what gets flagged is still worth keeping: false negatives silently lose usable trials, and false positives waste digitization effort on figures that turn out to lack a risk table. Need a figure showing the PFS KM curve **with a numbers-at-risk table** beneath it (required for unbiased reconstruction per Guyot et al. 2012). Expect real attrition — plausibly only 30–40% of candidates will have a usable figure. Track in a simple log:

| NCT ID | Has curve? | Has risk table? | Included? | Exclusion reason |
|---|---|---|---|---|

This log doubles as your eventual PRISMA-style flow diagram. PRISMA stands for **Preferred Reporting Items for Systematic Reviews and Meta-Analyses** — the standard reporting framework for systematic reviews, whose signature element is a flow diagram tracking records through identification → screening → eligibility assessment → final inclusion, with exclusion counts and reasons at each stage. For example: "142 NSCLC trials identified from CT.gov → 89 with a linked publication → 41 with a usable KM figure (risk table present) → 28 included in final dataset (61 excluded: 13 no risk table, 32 no linked publication with curve, 16 duplicate cohort)."

### Step 4 — Digitize the curves
Two approaches, with a meaningful automation/accuracy trade-off:

- **WebPlotDigitizer + IPDfromKM** (the semi-manual route described above): these are two separate, sequential tools. WebPlotDigitizer is a general-purpose browser tool for extracting (time, survival) coordinate points from the curve image via manual point-and-click — it has no survival-analysis logic of its own. IPDfromKM is a survival-specific R/Shiny app that takes those digitized points plus a manually transcribed risk table and reconstructs pseudo-individual-patient data by implementing the Guyot et al. (2012) algorithm.
- **KM-GPT**: a 2025 tool that uses image preprocessing plus a multimodal LLM (GPT-5) to automatically extract both the curve coordinates and the number-at-risk table, producing reconstructed patient-level data with no manual clicking or transcription — in contrast to IPDfromKM, which requires manually clicking points on the curve and manually entering the risk table.

| | WebPlotDigitizer + IPDfromKM | KM-GPT |
|---|---|---|
| Curve point extraction | Manual point-and-click | Automated (AI + image processing) |
| Risk table entry | Manual transcription | Automated extraction |
| Time per trial | Slower, scales linearly with study count | Faster, better suited to scaling across many trials |
| Accuracy control | Human directly verifies each click | Relies on model accuracy; less direct human oversight per point |
| Track record for this use case | Long-standing, widely used in IPD meta-analyses | Newer (2025); less established track record |

For a pilot batch, it's worth running both on the same handful of trials and comparing reconstructed curves/HRs before committing to one as your primary method — KM-GPT could substantially cut the manual burden at scale, but its outputs are worth validating against the manual method until you've built confidence in it for your specific figure types.

### Step 5 — Derive arm-level summary statistics
Fit KM/Cox model to reconstructed IPD → median PFS, log-HR vs. comparator arm. Where the paper also reports a HR directly in text, use that as the primary value and treat the reconstructed HR as a QC cross-check (reconstruction error is a known limitation of the method).

### Step 6 — Assemble the master datasets
See **Datasets to collect** below for the full variable lists (ORR dataset, PFS dataset, and the upstream digitization-inputs artifact) and the broader treatment-class taxonomy (not limited to PD-(L)1 agents).

## Datasets to collect

*Scope note: project covers all NSCLC treatment types (not PD-(L)1-only) and only ORR + PFS (no OS dataset, no % Asian race covariate — that was OS-specific in Franzese's model).*

### Dataset 1 — ORR dataset (cross-sectional: one row per study-stratum-arm)

| Variable | Description |
|---|---|
| Study ID | Unique study identifier (e.g., NCT number) |
| Stratum ID | Identifies stratified subgroup within study (e.g., PD-L1-stratified, biomarker-stratified), if applicable |
| Arm ID | Treatment arm within stratum — this is your linking key to Dataset 2 |
| Treatment (specific) | Specific drug/regimen name |
| Treatment class (broad) | Platinum-doublet chemo / EGFR TKI / ALK inhibitor / other targeted TKI / anti-angiogenic+chemo / IO monotherapy / IO+chemo / IO+IO combo / antibody-drug conjugate / other |
| Phase | 1 / 2 / 3 / undefined — study metadata |
| N (arm sample size) | Denominator |
| Responders / ORR | Numerator; proportion with CR or PR (RECIST 1.1) |
| Biomarker selection | Unselected (all-comers) / PD-L1-selected / EGFR-selected / ALK-selected / KRAS G12C-selected / other-driver-selected |
| PD-L1 expression % (negative/low/high/super-high) + computed average PD-L1 value | Collect only where clinically reported/relevant — don't force-impute for non-IO arms |
| Driver mutation % (if graded rather than binary) | Usually 100%/0% for selected/unselected trials; graded only if paper reports a mix |
| Age (mean, or median if mean missing) | |
| % Male | |
| % White | |
| % Squamous histology | Treat as a near-gating variable given biological confounding with treatment class |
| Treatment line | Neoadjuvant / adjuvant / 1L / 2L+ |
| % ECOG PS 0 | |
| % Never smoked | |
| % Prior therapy | |

### Dataset 2 — PFS dataset (longitudinal: one row per study-stratum-arm-per-month)

Built by feeding digitized KM curves + risk tables into the Guyot reconstruction algorithm.

| Variable | Description |
|---|---|
| Study ID / Stratum ID / Arm ID | Same key as Dataset 1 — how ORR and covariates get merged in |
| Month (k) | Discrete monthly interval index |
| Number at risk at start of interval k | From reconstructed IPD; interpolated where the published risk table only reports every 3–6 months |
| Number with event (progression) in interval k | Derived from the digitized curve drop between consecutive intervals |
| Observed ORR (arm-level, pulled from Dataset 1) | Used as a predictor, not re-measured here |
| Treatment class (broad, pulled from Dataset 1) | Needed if estimating a class-specific hazard-shift term (generalized from Franzese's chemo-only shift) |
| % Squamous histology, % ECOG PS 0 | Covariates carried into the PFS model |

### Upstream artifact — digitization inputs (not a modeling dataset, keep separately)

Per KM curve: raw (time, survival-probability) point pairs + transcribed number-at-risk table at each reported checkpoint. Keeping this separate from Dataset 2 lets you re-run the Guyot reconstruction later (e.g., if you revisit interpolation assumptions) without re-digitizing figures.

## Practical recommendation

Pilot the full pipeline on **10–15 trials** with likely-clean figures before scaling up the screening effort — cheaper to catch pipeline issues early than after screening 100+ candidates.
