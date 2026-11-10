# Building the data collection agent

The current agent is a Copilot Studio agent called by the R Shiny app (`app/`). The app sends it papers in batches, with the template's columns, the codebook and the disease rules, and the agent replies with JSON.

| File | What it's for |
|---|---|
| `agent_setup.txt` | What to enter in each field of Copilot Studio |
| `copilot_instructions.md` | The agent's instructions (paste into Copilot Studio) |
| `version1/` | The first, standalone version of the agent: its instructions, exclusion rules, toy DOI list, template and test answers |

The disease rules the app sends are in `app/defaults/collection_rules.txt` and `app/defaults/exclusion_rules.txt`.

To test the current agent, `version1/testing/expected_decisions.csv` still holds the reviewed decisions for the 12 trials in `version1/input_dois.csv`: upload that DOI list in step 2 of the app and compare (see `version1/README.md`, "Testing"). Note that the current agent flags overlaps as "POSSIBLE OVERLAP" instead of excluding them.
