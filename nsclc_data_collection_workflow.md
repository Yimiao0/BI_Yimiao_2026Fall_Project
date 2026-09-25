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

### Step 1 — Pull candidate trials via the CT.gov API and link their publications
ClinicalTrials.gov has a public REST API (v2, live since 2024): free, JSON responses, base endpoint:
```
https://clinicaltrials.gov/api/v2/studies
```
Script: `scripts/data_collection_scripts/01_pull_ctgov_candidates.R` (Stages 1–2).

Run from the project root:

```bash
Rscript scripts/data_collection_scripts/01_pull_ctgov_candidates.R
```

**Stage 1 — broad pull.** Query with `query.cond=Non-Small Cell Lung Cancer OR NSCLC`, `filter.overallStatus=COMPLETED`, `filter.advanced=AREA[StudyType]INTERVENTIONAL` only (paged via `nextPageToken`, 1,000 per page), so nothing gets dropped by an over-narrow server-side query. One row per study is written to `data/raw/step1_ctgov_raw_all_completed_interventional.csv` (NCT ID, title, phase, primary purpose, intervention types, status, sponsor, conditions, enrollment count, number of arms, has-posted-results flag). **2,791 studies** in the pull used here.

**Stage 2.1 — audit tabulations.** Tabulate intervention-type combinations, primary purpose, and phase across the raw pool (written to `step1_ctgov_intervention_type_tabulation.csv`, `step1_ctgov_primary_purpose_tabulation.csv`, `step1_ctgov_phase_tabulation.csv`) to inform the Stage 2.2 criteria.

**Stage 2.2 — inclusion criteria (applied together, a study must pass all four):**

| Criterion | Rule | Studies failing (of 2,791; not mutually exclusive) |
|---|---|---|
| Intervention type | At least one intervention type in {DRUG, BIOLOGICAL, COMBINATION_PRODUCT} | 327 |
| Primary purpose | `primaryPurpose == TREATMENT` | 319 |
| Phase | One of {PHASE1/PHASE2, PHASE2, PHASE2/PHASE3, PHASE3} — efficacy-focused stages; drops Phase 1-only, Early Phase 1, Phase 4, and phase not specified | 1,013 |
| Enrollment reported | Number of participants `enrollmentInfo.count` is not missing or 0 | 105 |

The "any intervention type" pull catches non-drug studies that `INTERVENTIONAL` alone in the stage 1 broad pull lets through — e.g. NCT05348187, a PCR diagnostic-kit performance study whose intervention type is DIAGNOSTIC_TEST. Intervention type `GENETIC` alone does not qualify - these studies usually refer to DNA sequencing such as PCR instead of gene-therapy; GENETIC studies that also list a DRUG/BIOLOGICAL intervention are kept.

**Result: 1,580 candidate trials** (1,211 excluded) → `data/raw/step1_ctgov_candidate_trials.csv`, plus **3,018 arm rows** (one per `armGroups` entry: arm label, type, description, keyed by NCT ID) → `data/raw/step1_ctgov_candidate_trial_arms.csv`, for later alignment with Dataset 1's Arm ID. Studies with no structured arm data get a single NA arm row, and `n_arms` is NA rather than 0 (common in pre-~2008 records).

**StudyType breakdown**:

| Value | Count |
|---|---|
| INTERVENTIONAL | 2,791 |
| OBSERVATIONAL | 581 |
| EXPANDED_ACCESS | 0 |

**InterventionType breakdown** (Stage 1's 2,791-study pool; a study can have >1 type):

| Value | Count |
|---|---|
| DRUG | 2,285 |
| BIOLOGICAL | 341 |
| RADIATION | 271 |
| OTHER | 267 |
| PROCEDURE | 213 |
| DEVICE | 49 |
| BEHAVIORAL | 43 |
| DIAGNOSTIC_TEST | 24 |
| DIETARY_SUPPLEMENT | 24 |
| GENETIC | 17 |
| COMBINATION_PRODUCT | 13 |

**Phase breakdown** (Stage 1 pool):

| Value | Count | Kept? |
|---|---|---|
| PHASE2 | 1,116 | ✓ |
| PHASE1 | 669 | |
| PHASE3 | 363 | ✓ |
| PHASE1; PHASE2 | 272 | ✓ |
| Not specified | 272 | |
| PHASE4 | 56 | |
| PHASE2; PHASE3 | 27 | ✓ |
| EARLY_PHASE1 | 16 | |

**Primary purpose breakdown** (Stage 1 pool):

| Value | Count | Kept? |
|---|---|---|
| TREATMENT | 2,472 | ✓ |
| DIAGNOSTIC | 89 | |
| SUPPORTIVE_CARE | 80 | |
| OTHER | 52 | |
| PREVENTION | 42 | |
| BASIC_SCIENCE | 16 | |
| SCREENING | 15 | |
| Not specified | 15 | |
| HEALTH_SERVICES_RESEARCH | 8 | |
| DEVICE_FEASIBILITY | 2 | |

**Stage 3 — link each trial to its publication DOI.** CT.gov's own "Results" module usually doesn't have K-M curves (e.g. NCT00638937 posts only median PFS and its 95% CI), so each trial needs its journal publication. Script: `scripts/data_collection_scripts/01b_link_nct_to_pubmed.R`. After Stages 1–2 finish, run from the project root:

```bash
Rscript scripts/data_collection_scripts/01b_link_nct_to_pubmed.R
```

1. **Pick the reference.** For each of the 1,579 candidates, read the trial's references on CT.gov (`referencesModule`). Use a `RESULT`-type reference (the sponsor marks it as this trial's results paper) first, then a `DERIVED` reference (added by CT.gov automatically from PubMed). `BACKGROUND` references (context such as earlier studies or RECIST) are never used.
2. **Get the DOI.** Because downstream screening requires locating and reading the publication, we retrieved the DOI whenever available. A PMID identifies the publication’s PubMed record, whereas a DOI generally provides a direct link to the article on the publisher’s website, making it more useful for locating the full text and supplementary materials. If the reference has a PMID, look up its DOI in PubMed (`rentrez`). Otherwise, or if PubMed has none, take the DOI from that reference's citation text. A reference without a DOI is skipped and the next one is tried; if no reference yields a DOI, the trial is marked "no publication found".
3. **Remove duplicate DOIs.** Some papers are linked to 2–3 trials (pooled reports, reviews, secondary analyses). For each DOI, only the earliest-registered trial (lowest NCT ID) is kept; the other 26 records are removed, leaving 1,553 trials.

Output: `data/raw/step1_nct_publication_links.csv`, one row per trial: reference type, PMID, DOI, citation, all RESULT/DERIVED PMIDs (`pmids_all`), and the full CT.gov reference list.

| Outcome | Trials | % of 1,553 |
|---|---|---|
| Found reference (with DOI) | 665 | 42.8% |
| No publication found | 888 | 57.2% |

The Step 1 counts feed Figure 1 (`scripts/data_collection_scripts/generate_prisma_figure_step1.R`).

### Step 2 — Screen publications for access and usable data
Starts from the publications found in Step 1 Stage 3. Script: `scripts/data_collection_scripts/02_access_and_screen_europepmc.R`. After Step 1 finishes, run from the project root:

```bash
Rscript scripts/data_collection_scripts/02_access_and_screen_europepmc.R
```

**Stage 1 — Classify publications using DOI into free-access or paywalled**
Among trials with available DOI, some of the publications are free to access so they might be accessible for AI like chatGPT or Claude, while others need institutional subscription to access and may need mannual data  collection. In this stage, we let the AI to explore each DOI to classify whether this publication belongs to free-access or paywalled.

**Stage 2 — Screen publications for usable ORR and PFS KM data**
Full-text can be filtered by keyword search for "Kaplan-Meier" or "K-M" — a paper that reports a KM analysis in its methods will almost always say so explicitly (same to ORR and PFS), so this is a reliable filter to cut down the candidate pool before formal data collection. This can be easily done by AI for the free-access publication with full-text online.

Europe PMC is a free public database of research papers (similar to PubMed). For each DOI it reports whether the paper is free to read, and for its open-access papers it provides the full text to search. Output: `data/raw/step2_nct_publication_links_with_doi.csv`, one row per trial with a DOI, with added columns `access_type`, `ORR_available`, `PFS_available`, `KM_available` (1 = mentioned in the full text, 0 = not, NA = full text not retrieved).

| Stage 1 access | Papers |
|---|---|
| Paywalled | 270 |
| Open access (full text available to search) | 206 |
| Free to read, but no full text available to search | 187 |
| Not found | 2 |

| Stage 2 screen (open-access papers only) | Papers |
|---|---|
| Mentions all of KM, PFS and ORR | 110 |
| Misses at least one | 94 |

The Step 2 counts feed Figure 2 (`scripts/data_collection_scripts/generate_prisma_figure_step2.R`).

### Step 3 — AI-assisted variable collection
Claude Code extracts the stratum-arm-level variables below, starting with the open-access and free-access publications that passed the Step 2 Stage 2 screen. It reads each paper's full text (via Europe PMC or PubMed Central) and fills one row per stratum-arm, citing the source table or figure in `notes`. Every row is then checked by hand against the paper. If time allows, full texts of paywalled publications, and of free ones whose journal sites block automated access, will be downloaded manually as PDFs for Claude Code to extract from in the same way.

Step 3 has no script. Start Claude Code from the project root (`claude`) and use this prompt, editing the trial selection and target sheet as needed:

```text
Do Step 3 of nsclc_data_collection_workflow.md (AI-assisted variable collection).

Trials: all trials in data/raw/step2_nct_publication_links_with_doi.csv that meet
both criteria:
- access_type is open_access or free_access
- ORR_available = 1, PFS_available = 1 and KM_available = 1
Skip trials already in the claude_collected or failed_open_free_papers sheet.

For each trial:
1. Get the full text: Europe PMC full-text XML for open-access papers, the PubMed
   Central article page for free papers with a PMCID, or the PDF if given.
   If you can't read the paper or can't fill any stratum-arm from it, add a row to
   the failed_open_free_papers sheet (nct_id, doi, reason) and move on.
2. Check that it is the trial's primary results paper for NSCLC. If it is a secondary
   analysis, another cancer type, or a special population (e.g. brain or
   leptomeningeal metastases only), still fill it but say so at the start of notes.
3. Fill one row per stratum-arm in the claude_collected sheet of
   data/raw/step3_stratum_arm_variables.xlsx, following the codebook sheet and its
   data-entry rules. Continue arm_id from the last existing row. Don't change
   existing rows, or any sheet other than claude_collected and
   failed_open_free_papers.
4. In notes, give the table/figure each value came from, which population was used
   (ITT, treated, measurable disease) when denominators differ, and anything unusual:
   time to progression or event-free survival instead of PFS, intracranial-only
   outcomes, counts derived from percentages, mean age instead of median.

Work in groups of 10 trials, in file order. For each group, fetch, read and fill
the 10 trials, then save to the workbook before starting the next group, so an
interruption loses at most the current group. Before each save, check that ECOG,
smoking and stage counts each add up to arm_sample_size where reported.

After each group is saved, report progress: group number, trials done so far out
of the total, arms filled and papers skipped (with reasons) in this group, and rows
in this group that need a closer look. Then continue with the next group without
waiting. At the end, give a short overall summary in the same format.
```

Output: `data/raw/step3_stratum_arm_variables.xlsx`, with five sheets:
- `claude_collected`: all stratum-arms Claude Code collects in Step 3
- `failed_open_free_papers`: open-access or free-access papers Claude Code couldn't fill, with NCT ID, DOI and the reason
- `claude_pilot`: a pilot test on a small number of publications (13 stratum-arms from 8 papers), done before the full collection
- `manual_pilot_check`: the pilot stratum-arms filled by hand, to check Claude Code's accuracy against `claude_pilot`
- `codebook`: column definitions and data-entry rules

Data-entry rules:
- Blank = not reported; 0 = reported as zero.
- Enter counts, not percentages (count = round(% × n) when only % is given).
- ECOG, smoking and stage counts each add up to `arm_sample_size`.

| Group | Variables | Notes |
|---|---|---|
| Identifiers | `arm_id`, `nct_id`, `doi`, `arm_label`, `stratum` | `arm_id` is unique per stratum-arm; `stratum` is "all" when the arm isn't split by stratum |
| Treatment | `arm_description`, `moa`, `participants_trt_status`, `biomarker_selection` | Drug + dose + schedule; mechanism of action; prior treatment / line; biomarker the arm was selected on (e.g. EGFR mutation, RET fusion, unselected) |
| Demographics | `arm_sample_size`, `median_age`, `female_count` | |
| ECOG performance status | `ECOG_0`, `ECOG_1`, `ECOG_0_1`, `ECOG_2`, `ECOG_3`, `ECOG_4`, `ECOG_Unknown` | `ECOG_0_1` is always filled, since many papers report only "0–1"; there's no ECOG 5 (death) |
| Smoking | `Tobacco_Never`, `Tobacco_Ever`, `Tobacco_Current`, `Tobacco_Former`, `Tobacco_Unknown` | Never + Ever + Unknown always filled; Current and Former only when the paper reports them separately |
| Stage | `stage_I_II`, `stage_IIIA`, `stage_IIIB`, `stage_IIIB_wet`, `stage_IIIC`, `stage_IV`, `stage_recurrent`, `stage_Unknown`, `ajcc_edition` | `stage_IIIB_wet` (malignant pleural effusion) is a subset of IIIB, only in AJCC 6th edition or earlier; AJCC = American Joint Committee on Cancer staging edition |
| Histology | `squamous_count`, `nonsquamous_count`, `histology_Unknown` | |
| Outcomes | `ORR`, `ORR_ci_low`, `ORR_ci_high`, `mPFS_months`, `mPFS_ci_low`, `mPFS_ci_high` | ORR as a proportion (0–1); median PFS converted to months |
| KM figure | `location_PFS_KM` | Figure holding the PFS KM curve |
| Notes | `notes` | Source tables/figures and anything unusual |



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
