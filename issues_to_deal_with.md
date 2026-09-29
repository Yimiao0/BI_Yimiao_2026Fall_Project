# Issues to Deal With

## 1. Non-NSCLC publication collected into `claude_collected` (arm 1)

**Status:** open

| Field | Value |
|---|---|
| `arm_id` | 1 |
| `nct_id` | NCT02681549 |
| `doi` | 10.1200/JCO-24-02219 |
| `arm_label` | pembrolizumab + bevacizumab |
| Sheet | `claude_collected` (moved to `irrelevant_arms` by `03_filter_irrelevant_arms.R`) |

**Problem.** The trial registered on ClinicalTrials.gov covers NSCLC plus brain metastases
in metastatic melanoma, so it passed the Step 1 NSCLC filter. The linked publication,
however, reports only the melanoma brain-metastases cohort and has no NSCLC patients. Its ORR
and median PFS are also intracranial-only. The Step 3 prompt says to fill such papers and
flag them in `notes`, so the arm entered the dataset sheet and had to be filtered out
afterwards.

**To do.** Refine the data collection process/prompt so that an arm like this is not
added to `claude_collected` in the first place. For example, in the Step 3 prompt, when the
linked paper reports no NSCLC patients, log it in `failed_open_free_papers` with reason
"Wrong population: not NSCLC (…)" instead of filling it.
