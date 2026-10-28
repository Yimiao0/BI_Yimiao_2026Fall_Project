# Exclusion rules

The analysis population is **systemic therapy for advanced or metastatic NSCLC**. Exclude a paper or arm when its ORR or PFS can't fairly be compared with that population. Apply only the rules switched on in the settings of `agent_instructions.md`.

Use exactly one code. If more than one applies, use the lowest number:

Paper type (always paper-level):

1. `TRIAL_MISMATCH`: the paper reports a different trial than `nct_id`
2. `PROTOCOL_ONLY`: study protocol with no results
3. `NO_ARM_LEVEL_RESULTS`: no arm-level baseline, ORR or PFS

Out of scope (paper- or arm-level):

4. `NOT_NSCLC`: patients are not mostly NSCLC
5. `SURGICAL`: surgery is part of the planned treatment
6. `DEFINITIVE_CRT`: curative-intent chest radiation with chemotherapy
7. `INTRACRANIAL_ORR`: ORR counts brain lesions only
8. `ON_TREATMENT_SUBGROUP`: strata defined by an event during treatment
9. `OVERLAP`: patients already counted in another included arm

A paper you couldn't get or read is not excluded; it goes to the `failed_papers` sheet.

For each excluded paper or arm, write one row to the `excluded` sheet of `output_template.xlsx`, filling its columns as defined in that file's `codebook` sheet.

Decide from the arm's planned treatment and population, not from words that appear in the paper.

---

## 1. TRIAL_MISMATCH

**Exclude:** papers that name a different NCT number, or report a different study than the trial in `nct_id`. Give the number or study it names in `exclusion_evidence`.

## 2. PROTOCOL_ONLY

**Exclude:** study protocols and design papers that report no results.

## 3. NO_ARM_LEVEL_RESULTS

**Exclude:** papers with no arm-level baseline, ORR or PFS, such as pooled analyses across trials, biomarker-only, pharmacogenetic, modelling, cost-effectiveness, quality-of-life and methods papers.

## 4. NOT_NSCLC

**Exclude:**
- Other-cancer cohorts of basket trials
- Small-cell lung cancer
- Brain metastases from primaries other than NSCLC
- Arms where NSCLC patients are a small minority

A trial registered as NSCLC can have a paper that reports only another cancer. Exclude it with this code; don't put it in `failed_papers`.

## 5. SURGICAL

**Exclude:** neoadjuvant, preoperative or perioperative therapy, and surgery alone.

## 6. DEFINITIVE_CRT

**Exclude:** curative-intent chest radiation given with chemotherapy, with or without another drug.

## 7. INTRACRANIAL_ORR

**Exclude:** arms whose only ORR is intracranial, for example RANO-BM or "CNS ORR".

## 8. ON_TREATMENT_SUBGROUP

**Exclude:** strata defined by something that happened after treatment started, such as side effects, early response, dose reductions or treatment duration.

## 9. OVERLAP

**Exclude** a subgroup, regional extension or later trial phase whose parent trial is already in the `included_arms` sheet (search it by NCT number or trial name):
- Regional subgroup of a global trial
- Regional extension study of a global trial
- Later phase of included arms, such as the maintenance phase of a trial whose first-line arms are included
