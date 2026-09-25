# Presentation tables (nsclc_data_collection_workflow.md, Step 1 Stage 2.1):
# top-7 + "Other" summaries of the Stage 1 raw pool by intervention type,
# phase, and primary purpose -- one sheet per table.
#
# Reads the tabulation CSVs already written by 01_pull_ctgov_candidates.R;
# no network calls. Summary cells are Excel formulas linked to a full
# tabulation printed below each table, so "Other" and "Total" are never
# hardcoded.
#
# Input:  data/raw/step1_ctgov_intervention_type_tabulation.csv
#         data/raw/step1_ctgov_phase_tabulation.csv
#         data/raw/step1_ctgov_primary_purpose_tabulation.csv
# Output: figures/step1_type_summary_tables.xlsx
#
# Requires: pandas, openpyxl. Run from anywhere:
#   python3 scripts/data_collection_scripts/generate_step1_summary_tables.py

from pathlib import Path

import pandas as pd
from openpyxl import Workbook
from openpyxl.styles import Font, PatternFill, Alignment, Border, Side
from openpyxl.workbook.properties import CalcProperties

ROOT = Path(__file__).resolve().parent.parent
RAW = f"{ROOT}/data/raw"
OUT = f"{ROOT}/figures/step1_type_summary_tables.xlsx"
TOP_N = 7

# Step 1 Stage 2.2 acceptance rules -- keep in sync with KEEP_IF_ANY_TYPE,
# KEEP_IF_PHASE and the pass_purpose check in 01_pull_ctgov_candidates.R.
KEEP_IF_ANY_TYPE = {"DRUG", "BIOLOGICAL", "COMBINATION_PRODUCT"}
KEEP_IF_PHASE = {"PHASE1; PHASE2", "PHASE2", "PHASE2; PHASE3", "PHASE3"}
KEEP_IF_PURPOSE = {"TREATMENT"}

# (sheet name, input CSV, category column, display label, accepted-category test)
SHEETS = [
    ("Intervention Type", "step1_ctgov_intervention_type_tabulation.csv",
     "intervention_types", "Intervention type",
     lambda v: bool(set(v.split("; ")) & KEEP_IF_ANY_TYPE)),
    ("Phase", "step1_ctgov_phase_tabulation.csv", "phase", "Phase",
     lambda v: v in KEEP_IF_PHASE),
    ("Primary Purpose", "step1_ctgov_primary_purpose_tabulation.csv",
     "primary_purpose", "Primary purpose",
     lambda v: v in KEEP_IF_PURPOSE),
]

FONT = "Arial"
title_font = Font(name=FONT, size=14, bold=True)
note_font = Font(name=FONT, size=9, italic=True, color="595959")
hdr_font = Font(name=FONT, size=11, bold=True, color="FFFFFF")
body_font = Font(name=FONT, size=11)
bold_font = Font(name=FONT, size=11, bold=True)
sub_font = Font(name=FONT, size=11, bold=True, color="404040")
hdr_fill = PatternFill("solid", start_color="1F4E79")
other_fill = PatternFill("solid", start_color="F2F2F2")
accept_fill = PatternFill("solid", start_color="E2EFDA")
thin = Side(style="thin", color="BFBFBF")
top_rule = Border(top=Side(style="medium", color="1F4E79"))
bottom_line = Border(bottom=thin)

wb = Workbook()
wb.remove(wb.active)

for sheet_name, csv, col, label, accepted in SHEETS:
    # keep_default_na=False so the literal phase value "NA" is not read as missing
    df = pd.read_csv(f"{RAW}/{csv}", keep_default_na=False)
    df = df.sort_values("n_studies", ascending=False, kind="stable").reset_index(drop=True)
    n_types = len(df)
    df["accepted"] = df[col].astype(str).map(accepted)

    ws = wb.create_sheet(sheet_name)
    ws["A1"] = f"Completed interventional NSCLC trials by {label.lower()}"
    ws["A1"].font = title_font
    ws["A2"] = (f"Source: ClinicalTrials.gov v2 API, Step 1 Stage 1 raw pool ({csv}). "
                f"Top {TOP_N} categories by trial count; all remaining categories summed into \"Other\".")
    ws["A2"].font = note_font

    # --- Summary table (rows 4..) ---
    hdr_row = 4
    for c, text in enumerate([label, "Number of trials"], start=1):
        cell = ws.cell(row=hdr_row, column=c, value=text)
        cell.font, cell.fill = hdr_font, hdr_fill
        cell.alignment = Alignment(horizontal="left" if c == 1 else "right")

    first_sum = hdr_row + 1
    n_shown = min(TOP_N, n_types)
    other_row = first_sum + n_shown
    total_row = other_row + 1

    # Full tabulation lives below the summary; summary cells link to it.
    detail_title = total_row + 4
    detail_hdr = detail_title + 1
    detail_first = detail_hdr + 1
    detail_last = detail_first + n_types - 1

    for i in range(n_shown):
        r = first_sum + i
        ws.cell(row=r, column=1, value=f"=A{detail_first + i}")
        ws.cell(row=r, column=2, value=f"=B{detail_first + i}")
        for c in (1, 2):
            ws.cell(row=r, column=c).font = body_font
            ws.cell(row=r, column=c).border = bottom_line
            if df.loc[i, "accepted"]:
                ws.cell(row=r, column=c).fill = accept_fill

    ws.cell(row=other_row, column=1, value="Other")
    rest_first = detail_first + TOP_N
    ws.cell(row=other_row, column=2,
            value=f"=SUM(B{rest_first}:B{detail_last})" if n_types > TOP_N else 0)
    for c in (1, 2):
        cell = ws.cell(row=other_row, column=c)
        cell.font, cell.fill, cell.border = body_font, other_fill, bottom_line

    ws.cell(row=total_row, column=1, value="Total")
    ws.cell(row=total_row, column=2, value=f"=SUM(B{first_sum}:B{other_row})")
    for c in (1, 2):
        cell = ws.cell(row=total_row, column=c)
        cell.font, cell.border = bold_font, top_rule

    n_rest = max(n_types - TOP_N, 0)
    ws.cell(row=total_row + 1, column=1,
            value=f"\"Other\" combines {n_rest} remaining categor{'y' if n_rest == 1 else 'ies'}"
                  + (" (none — no remaining categories)." if n_rest == 0 else
                     "; see full tabulation below.")).font = note_font
    n_other_accepted = int(df.loc[TOP_N:, "n_studies"][df.loc[TOP_N:, "accepted"]].sum())
    ws.cell(row=total_row + 2, column=1,
            value="Green rows: categories accepted by the Step 1 filter on this criterion"
                  + (f" (\"Other\" is mixed: {n_other_accepted:,} of its trials fall in accepted categories)."
                     if n_other_accepted else ".")).font = note_font

    # --- Full tabulation (source values) ---
    ws.cell(row=detail_title, column=1, value="Full tabulation (source for the table above)").font = sub_font
    for c, text in enumerate([label, "Number of trials"], start=1):
        cell = ws.cell(row=detail_hdr, column=c, value=text)
        cell.font, cell.border = bold_font, bottom_line
        cell.alignment = Alignment(horizontal="left" if c == 1 else "right")
    for i, row in df.iterrows():
        r = detail_first + i
        ws.cell(row=r, column=1, value=str(row[col])).font = body_font
        ws.cell(row=r, column=2, value=int(row["n_studies"])).font = Font(name=FONT, size=11, color="0000FF")
        if row["accepted"]:
            for c in (1, 2):
                ws.cell(row=r, column=c).fill = accept_fill

    for r in range(first_sum, detail_last + 1):
        ws.cell(row=r, column=2).number_format = "#,##0"
    ws.column_dimensions["A"].width = max(34, df[col].astype(str).str.len().max() + 4)
    ws.column_dimensions["B"].width = 18
    ws.freeze_panes = None

# No LibreOffice here to cache values; force Excel/Numbers to compute on open.
wb.calculation = CalcProperties(fullCalcOnLoad=True)
wb.save(OUT)

# Verification: recompute expected summary values in pandas.
for sheet_name, csv, col, label, accepted in SHEETS:
    df = pd.read_csv(f"{RAW}/{csv}", keep_default_na=False).sort_values(
        "n_studies", ascending=False, kind="stable")
    top = df.head(TOP_N)
    print(f"\n== {sheet_name}")
    print(top.to_string(index=False))
    print("Other:", df["n_studies"].iloc[TOP_N:].sum(), "| Total:", df["n_studies"].sum())
print("\nSaved", OUT)
