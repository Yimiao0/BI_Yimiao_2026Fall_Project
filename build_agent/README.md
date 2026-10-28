# Files for building the data collection agent

The agent reads each trial's DOI, gets the paper's full text, and fills one row per stratum-arm. As it goes, it excludes whole papers whose study is out of scope (for example, neoadjuvant or small-cell trials) and single arms that are out of scope (for example, non-NSCLC cohorts of a basket trial), each with a reason code. No filtering script is needed afterwards.

## What to upload to the agent builder

| File | Put it in | What it does |
|---|---|---|
| `agent_instructions.md` | **Instructions** (paste as the agent's main prompt) | Step-by-step procedure, include/exclude decisions, data-entry rules, notes style, progress reports. Edit the **Settings for this run** block at the top before each run. |
| `exclusion_rules.md` | Knowledge | Definitions of the nine exclusion codes |
| `output_template.xlsx` | Output file the agent writes to | Empty sheets `included_arms`, `excluded`, `failed_papers`, plus a `codebook` sheet defining every column of those three sheets, including the exclusion and failure codes |
| `input_dois.csv` / `input_dois.xlsx` | Input file (same list; use the `.xlsx` if the builder can't upload CSV) | Toy set of 12 trials, chosen from the 170 whose free full text mentions ORR, PFS and Kaplan-Meier. They cover every kind of decision: 5 included only, 2 with some arms excluded, 5 excluded as whole papers |

If the builder can't upload `.md` or `.csv` files, upload `agent_instructions.txt`, `exclusion_rules.txt` and `input_dois.xlsx` instead. The `.txt` files have the same content as the `.md` files, but refer to `.txt` and `input_dois.xlsx` names; `agent_setup.txt` uses the `.txt` names. After editing a `.md` file, recreate its `.txt` copy (see "Regenerating the data files").

If the builder has only one place for files, upload everything and paste `agent_instructions.md` into the instructions box as well.

**Check before building:** the agent must be able to open web pages (Europe PMC, PubMed Central, doi.org). If the builder can't make web requests, the agent will need the papers uploaded as PDFs.

`agent_setup.txt` lists what to enter in each field when building the agent (name, description, instructions, knowledge files) and the prompt that starts a run. It's for you; don't upload it.

## Output

| Sheet | One row per | Columns |
|---|---|---|
| `included_arms` | stratum-arm in the analysis population | the 44 `included_arms` columns in the codebook |
| `excluded` | excluded paper or excluded stratum-arm | `nct_id`, `doi`, `exclusion_level` (paper / arm), `arm_label`, `stratum` (blank for a paper), `exclusion_code`, `exclusion_evidence`. Excluded arms are not filled in detail. |
| `failed_papers` | paper the agent couldn't get or read | `nct_id`, `doi`, `reason` |

The agent also writes `progress_log.txt`: each progress report (every 5 papers) and the final summary, with the date and time, added to the end of the file.

Exclusion codes, paper type (paper-level only): `TRIAL_MISMATCH`, `PROTOCOL_ONLY`, `NO_ARM_LEVEL_RESULTS`.
Exclusion codes, out of scope (paper- or arm-level): `NOT_NSCLC`, `SURGICAL`, `DEFINITIVE_CRT`, `INTRACRANIAL_ORR`, `ON_TREATMENT_SUBGROUP`, `OVERLAP`.

Rows that need a person's attention have a flag at the start of `notes`: `CHECK:`, `POSSIBLE OVERLAP:`, `SECONDARY ANALYSIS:` or `SPECIAL POPULATION:`.

## Testing the agent

`testing/expected_decisions.csv` holds the reviewed decision for every arm and paper from the earlier Claude Code run: 199 arms included, 50 papers and 9 arms excluded. The earlier run had no papers it couldn't read, so there are no failed rows to compare. The `level` column says whether each decision is for a paper or an arm. This file is **for you, not the agent**. Don't upload it, or the agent will copy the answers.

1. Run the agent on the 12 trials in `input_dois.csv`.
2. For each trial, compare the agent's sheet and code with `expected` and `code` in the test file.
3. Check two numbers:
   - Of the papers and arms the test file excludes, how many did the agent also exclude, at the same level?
   - Of the arms the test file includes, how many did the agent wrongly exclude?
4. Spot-check a few included rows' values against the earlier dataset (`data/raw/step3_stratum_arm_variables.xlsx`, sheet `claude_collected`).

If the agent gets a rule wrong, add the case as an example under that rule in `exclusion_rules.md`. Usually that works better than rewording the rule.

## Regenerating the data files

`input_dois.csv`, `input_dois.xlsx`, `output_template.xlsx` and `testing/expected_decisions.csv` are made from the project's Step 2 and Step 3 outputs. Run this from the project root:

```bash
Rscript scripts/make_build_agent_files.R
```

The two `.md` files are written by hand. To recreate their `.txt` copies after editing, run this from `build_agent/`:

```bash
for f in agent_instructions exclusion_rules; do
  sed -e 's/agent_instructions\.md/agent_instructions.txt/g' -e 's/exclusion_rules\.md/exclusion_rules.txt/g' -e 's/input_dois\.csv/input_dois.xlsx/g' $f.md > $f.txt
done
```
