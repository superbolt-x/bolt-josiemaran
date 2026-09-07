# Runbook — Josie Maran automated reporting

Everything that could be built without warehouse write access or a Sheets API is
built. This is what's left, in order, with the reasoning for each step.

---

## What is already done

| | Where |
|---|---|
| dbt models — blended, catalog segment, shopify segment | `models/reporting/` |
| Taxonomy macros — 3 naming conventions | `macros/jm_taxonomy.sql`, `macros/parse_campaign_tag.sql` |
| Source declaration for the catalog segment tables | `models/reporting/_sources.yml` |
| Schema + data tests | `models/reporting/blended.yml`, `tests/` |
| Metabase feed card (dbt-backed, final) | `metabase/01_reporting_feed.sql` |
| Metabase feed card (standalone, runs today) | `metabase/generated/01_reporting_feed_standalone.sql` |
| dbt → standalone compiler | `scripts/build_standalone_feed.py` |
| SQL static validator | `scripts/validate_sql.py` |
| Apps Script that builds the whole sheet | `scripts/build_gsheet.gs` |
| Metabase collection **“Josie Maran — Automated Reporting”** | id **4503**, created |
| Sheet layout + formula spec | `docs/gsheet_structure.md` |

**Not run, and why:** no dbt binary, no `profiles.yml`, no `dbt_packages/` in
this environment, and the warehouse connection available here is read-only
`SELECT`. So `dbt deps` / `dbt run` / `dbt test` are step 2 below. The generated
standalone SQL was **statically validated, not executed** — see step 1.

---

## Step 0 · Decide two things first (5 min, blocks nothing else)

1. **Should the new SB traffic campaigns be inside the Sephora catalog
   partnership?** They carry ~92% of live Sephora spend and emit no
   catalog-segment rows. If the linkage can be restored in Ads Manager, Sephora
   measurement comes back. Nothing in this build depends on the answer, but it's
   the highest-value fix on the account.
2. **Market for untagged DTC campaigns.** `SB - DTC Prospecting Advantage+` has
   no `reg:` tag and is the main live DTC purchase campaign. The macro defaults
   it to `US` (19,552 of 19,636 Shopify orders ship US). If you'd rather it be
   `Unknown`, change the last branch of `jm_market` in `macros/jm_taxonomy.sql`.

---

## Step 1 · Sanity-check the standalone SQL (10 min)

This is the card that lets you build the sheet **before** dbt has run. It was
compiled from the model files, so it cannot drift from the dbt version.

```bash
python3 scripts/validate_sql.py metabase/generated/01_reporting_feed_standalone.sql
```

Expected: `PASS  (37,123 chars, 864 lines)` with five ✓ lines. It checks for
unrendered Jinja, unbalanced parens, duplicate CTE names, unresolved FROM/JOIN
targets, and misaligned UNION branches.

Then run it once in Metabase's native editor (**+ New → SQL query →
Redshift/josiemaran**, paste the file, ⌘↵). Two things to look at:

- **~650 rows.** If it's ~0, the catalog-segment join or a date window is off.
- **Acceptance values.** Filter to `report_level = 'Sephora Segment'` and
  `period_label = '2026-W36'` and compare against this table, which was measured
  directly against the warehouse on 2026-09-07:

| `lookup_key` | spend | cs_purchases | cs_revenue | cs_roas |
|---|---|---|---|---|
| `Sephora Segment\|Sephora – Total\|All\|2026-W36` | 15,974.29 | 148 | 5,837.00 | 0.37 |
| `Sephora Segment\|US Traffic\|All\|2026-W36` | 12,091.46 | 2 | 98.00 | 0.01 |
| `Sephora Segment\|CA Traffic\|All\|2026-W36` | 1,979.70 | 1 | 36.00 | 0.02 |
| `Sephora Segment\|US Collab\|All\|2026-W36` | 852.15 | 106 | 4,104.00 | 4.82 |
| `Sephora Segment\|CA Collab\|All\|2026-W36` | 344.45 | 39 | 1,599.00 | 4.64 |
| `Sephora Segment\|Kohls Traffic\|All\|2026-W36` | 706.53 | *(blank)* | *(blank)* | *(blank)* |
| `Site\|All\|All\|2026-W36` | — | 2,963 orders | 213,127.45 gross | — |

If US Collab and CA Collab show ~4.8 and ~4.6 ROAS against Traffic at ~0.01,
the catalog-segment join is working. That contrast **is** the finding.

*(Note: `2026-W36` is the week beginning 2026-08-31. Once time moves on, compare
whichever week is most recent instead — the shape is what matters.)*

---

## Step 2 · Save the Metabase question (5 min)

1. **+ New → SQL query**, database **Redshift / josiemaran**.
2. Paste `metabase/generated/01_reporting_feed_standalone.sql`.
3. Save as **`JM – Reporting Feed`** into collection
   **“Josie Maran — Automated Reporting”** (id 4503, already created).
4. **Do not add any filter widget or template tag.** Parameter-free is what
   keeps the card usable by the extension and publishable as a public CSV.
   Market and period selection happen in the sheet.

Note the question id — you'll need it for the extension.

---

## Step 3 · Connect the extension (5 min)

1. Open the [reporting sheet](https://docs.google.com/spreadsheets/d/18-_3YywVlSxrz5jLUJ0-K-YRqkFWrpl0KB6m_iOMB_Y/edit).
2. Rename `Sheet1` to **`feed`** (exact, lowercase).
3. Point the extension at question `JM – Reporting Feed`, target tab `feed`,
   **header row in row 1**, starting cell `A1`.
4. Refresh once. You should get 1 header row + ~650 data rows, 38 columns (A:AL).

Check column headers land as: `A report_level`, `H lookup_key`, `AI data_valid`,
`AJ has_catalog_feedback`, `AK status`, `AL detail`. The grids find metrics by
header *name*, so a metric moving is fine — but `H`, `AI`, `AJ` are referenced by
letter in the conditional formats, so tell me if those shift.

**If the extension can't be used:** the card has no template tags, so
`=IMPORTDATA("https://metabase-superbolt.com/public/question/<uuid>.csv")` works
off a public link. That link is unauthenticated — aggregate spend/revenue, no
PII, but it needs sign-off and the UUID should be rotated if the sheet's
audience changes.

---

## Step 4 · Build the sheet (2 min, scripted)

1. **Extensions → Apps Script**.
2. Delete the placeholder `myFunction`, paste all of `scripts/build_gsheet.gs`, **Save**.
3. **Run ▸ `buildReport`**. Authorise when prompted (it only touches this file).

It creates `README`, `Health`, `Sephora WoW`, `DTC WoW`, `Monthly`, `Site`,
`Campaigns`, `Config` — with every formula, number format, conditional format
and frozen pane. It **never touches `feed`**. Safe to re-run.

To change which rows appear or their order, edit the `CONFIG` object at the top
of the script and re-run. `row_label` must match the feed's `row_label` exactly
(note the en-dash in `Sephora – Total`).

**Then read the two colours:**
- **Amber** on Sephora blocks = real spend, conversions not reported. Act on it.
- **Grey** on DTC blended blocks = the data doesn't exist for that period.
  Ignore it; don't try to backfill.

---

## Step 5 · Run dbt (15 min, needs warehouse write access)

Everything above works without this. This is what makes the model reusable by
other cards and dashboards, and adds the tests.

```bash
dbt deps
dbt run  --select shopify_sales_by_segment facebook_catalog_segment_performance blended_performance
dbt test --select blended_performance shopify_sales_by_segment
```

Then swap the Metabase question's SQL to `metabase/01_reporting_feed.sql` — the
same final SELECT, reading `reporting.josiemaran_blended_performance` instead of
850 lines of inlined CTEs. Nothing in the sheet changes. Delete
`metabase/generated/`.

### Two tests are expected to FAIL, by design

- **`assert_sephora_spend_has_catalog_segment`** — fires while >20% of
  trailing-30-day Sephora spend has no catalog feedback. Currently ~92%. It
  clears when step 0.1 is resolved, not by editing the test.
- **`assert_no_unclassified_spend`** — fires above 1% of trailing-90-day spend.
  Should pass now (unclassified is ~$0 on Meta after the three-convention
  taxonomy), but it will fire the moment a campaign launches outside all three
  naming conventions. That's the point.

### If a `ref()` fails to resolve

The models reference package models by name: `facebook_performance_by_campaign`,
`googleads_performance_by_campaign`, `shopify_daily_sales_by_order`. If the
installed package versions expose different names, fix the `ref()` in the model
and re-run `python3 scripts/build_standalone_feed.py` so the standalone stays in
sync. The compiler's `BASE_TABLES` map is the place to check.

---

## Step 6 · Things worth doing, not blocking

- **Fivetran: Shopify order backfill.** Order history starts 2026-07-27. If it
  can reach further back, DTC blended MoM and eventually YoY become possible. If
  it can't, DTC is weekly-blended until October — set that expectation with
  marketing now rather than in a review.
- **Region tag case.** `reg:us` / `reg:US` / `reg:CA` / `reg:ca` all occur.
  Handled with `lower()`, but worth fixing at the naming end.
- **The retired ATC campaigns.** US ATC ran at 0.67 ROAS / $64 CPA and CA ATC at
  1.34 / $30 — worse than Collab, an order of magnitude better than Traffic. The
  deck paused them for having no pixel feedback loop; the catalog-segment data
  says they were converting. Worth a second look.
- **Unbuilt sources.** `ga4_raw` exists in the warehouse with no reporting model,
  so there's no session or site-CVR reporting. Klaviyo and Recharge are likewise
  unbuilt — the latter notable given subscriptions are 21% of orders.
- **TikTok**, if it stops being a placeholder: the conversion metric group isn't
  syncing at all ($292,756 spend, 145M impressions, zero conversions ever). The
  revenue mapping bug in `tiktok_ad_performance.sql` is already fixed.
- **Bing / Pinterest** are `enabled = false`. Delete the four disabled models if
  they're definitively not coming.

---

## Rebuilding after any model change

```bash
python3 scripts/build_standalone_feed.py                                   # recompile
python3 scripts/validate_sql.py metabase/generated/01_reporting_feed_standalone.sql
```

Then re-paste into Metabase (pre-dbt) or just `dbt run` (post-dbt). The
generated file is machine-written — don't hand-edit it.
