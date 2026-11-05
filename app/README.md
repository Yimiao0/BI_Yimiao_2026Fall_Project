# Trial data collection app (R Shiny)

A two-step web app for colleagues:

1. **Find publications.** Enter a disease, phase(s) and status. The app searches ClinicalTrials.gov, links each trial to its results paper in PubMed, optionally checks open access in Europe PMC, and returns the DOI list as Excel.
2. **Collect data.** Give it the DOI list, an empty output template and a codebook. The data-collection agent reads each paper and fills the template, which the user downloads.

The agent is currently a **placeholder** (test mode) that returns made-up rows, so the whole app can be tried before a real agent exists.

## Files

| File | What it does |
|---|---|
| `app.R` | Page layout and app logic |
| `R/search_trials.R` | Step 1: ClinicalTrials.gov search, filters, PubMed DOI lookup, Europe PMC access check. Same rules as `scripts/data_collection_scripts/01_*.R`, `01b_*.R` and the access part of `02_*.R` |
| `R/agent.R` | Step 2: reads the template and codebook, calls the agent once per paper, writes the results into the template |
| `python/copilot_agent.py`, `requirements.txt` | Connection to the Copilot Studio agent through Microsoft's Python SDK |
| `R/utils.R` | Progress reporting for long runs |
| `defaults/` | Default template, agent instructions and exclusion rules, copied from `build_agent/` |
| `manifest.json` | Package list Posit Connect needs to install the app |

## Run it on your computer

In R, from the project root:

```r
shiny::runApp("app")
```

## Publish on Posit Connect from GitHub

1. Push the repo to GitHub, including `app/manifest.json`.
2. In Posit Connect: **Publish → Import from Git**. Enter the repo URL and branch `main`, and pick the `app` folder.
3. Connect installs the packages listed in `manifest.json` and starts the app. It re-deploys automatically when you push to the branch, if you turn that on.
4. Under **Access**, choose who can open the app.

**Update `manifest.json` when you add an R or Python package or upgrade R:**

```r
rsconnect::writeManifest(appDir = "app", appPrimaryDoc = "app.R", python = "app/.venv/bin/python")
```

The manifest records R 4.3.3. If Connect doesn't have that version, it uses the nearest one it has; ask your Connect admin if deployment fails on the R version.

## Settings (environment variables)

Set these in Posit Connect under **Vars**, or in `~/.Renviron` locally. Never put keys in the code.

| Variable | Needed? | Meaning |
|---|---|---|
| `AGENT_BACKEND` | no | `mock` (default, placeholder agent), `copilot` (Copilot Studio agent) or `http` (other hosted agent) |
| `COPILOT_CONNECTION_STRING` | with `copilot` | The connection string from Copilot Studio → Channels → App → Microsoft 365 Agents SDK |
| `COPILOT_TENANT_ID`, `COPILOT_CLIENT_ID` | with `copilot`, on your computer only | Entra ID tenant and app registration, for signing in through the browser |
| `COPILOT_TIMEOUT_SECONDS` | no | How long to wait for the agent per paper (default 900) |
| `AGENT_URL`, `AGENT_API_KEY` | with `http` | Web address and key of another hosted agent |
| `NCBI_API_KEY` | no | Faster PubMed lookups (free key from NCBI) |

## Copilot Studio agent

The app talks to the agent with Microsoft's Python SDK (`python/copilot_agent.py`), called from R through `reticulate`. Each paper is sent in a new conversation, and the agent replies with JSON rows that the app writes into the template. The agent runs under the signed-in colleague's Microsoft account.

**One-time setup (needs IT / admins):**

1. **Entra ID app registration** with the delegated API permission **`CopilotStudio.Copilots.Invoke`** (under Power Platform API), admin-consented.
   - For testing on your computer: add the platform "Mobile and desktop applications" with redirect URI `http://localhost`.
   - For Posit Connect: add a client secret and Connect's OAuth redirect URI (your Connect admin provides it).
2. **Posit Connect OAuth integration** for Microsoft Entra ID using that app registration, with scope `https://api.powerplatform.com/.default` (plus `offline_access`). Then attach the integration to this app (app settings → Access → Integrations).
3. **Publish the agent** in Copilot Studio and share it with the colleagues who will use the app.

**Agent instructions:** the app's message for each paper asks for one paper and a JSON reply (see `copilot_message()` in `R/agent.R`). Add a line to the agent's instructions in Copilot Studio so it doesn't try to write an Excel file, e.g.:

> When a message gives one paper and asks for a JSON reply, process only that paper and reply with the JSON object only. Don't write files.

**Test on your computer first:**

```bash
cd app
python3.11 -m venv .venv
.venv/bin/pip install -r requirements.txt
```

Then put `AGENT_BACKEND=copilot`, `COPILOT_CONNECTION_STRING`, `COPILOT_TENANT_ID` and `COPILOT_CLIENT_ID` in `~/.Renviron`, restart R, and run the app. The first "Run the agent" opens a Microsoft sign-in page. Try 2–3 DOIs first.

**On Posit Connect:** Connect builds the Python environment from `requirements.txt` (the version is recorded in `manifest.json`). Set `AGENT_BACKEND=copilot` and `COPILOT_CONNECTION_STRING` under **Vars**. Connect must have Python 3.10 or later.

**Token lifetime:** the sign-in token is taken when the run starts and usually lasts about an hour. For long runs, split the DOI list into batches.

## Plugging in another agent

The app only calls the agent through `agent_process_paper()` in `R/agent.R`, once per paper. The agent receives the paper (`nct_id`, `pmid`, `doi`, `access_type`, `citation`), the template's column names per sheet, the codebook text, and the instructions from `defaults/`. It returns rows per sheet, for example:

```json
{"included_arms": [{"arm_label": "Arm A", "arm_sample_size": 120}],
 "excluded": [],
 "failed_papers": []}
```

- **An agent with a simple web API:** make it accept and return that JSON (the contract is at the top of `agent_http()`), then set `AGENT_BACKEND=http`, `AGENT_URL` and `AGENT_API_KEY`.
- **Any other agent** (e.g. Copilot Studio through Direct Line, or a model API): write a new `agent_<name>()` function with the same arguments and return value as `agent_mock()`, and add it to the `switch()` in `agent_process_paper()`.

The rest of the app doesn't change.

## Notes

- After editing `build_agent/output_template.xlsx`, `agent_instructions.txt` or `exclusion_rules.txt`, copy them into `app/defaults/` again.
- Long steps run in a background R process, so one user's run doesn't block others. The app keeps two background workers; raise `workers` in `app.R` if several people run it at once.
- A very broad search (e.g. just "cancer") stops early if it matches more trials than the limit under **More filters**.
