# Runbook — Josie Maran automated reporting

Current state and the manual steps left, in order.

---

## Built

| | Where |
|---|---|
| Campaign ID → segment mapping (from the deck) | `seeds/campaign_segments.csv` — 15 campaigns, 7 segments |
| dbt models — blended, catalog segment, TikTok campaign, shopify segment | `models/reporting/` |
| Generated segment macro | `macros/jm_campaign_segments.sql` |
| Schema + 3 data tests | `models/reporting/blended.yml`, `tests/` |
| **Metabase question `JM – Reporting Feed`** | **[57484](https://metabase-superbolt.com/question/57484)** in collection **4503** |
| Standalone (pre-dbt) feed SQL | `metabase/generated/01_reporting_feed_standalone.sql` |
| dbt → standalone compiler | `scripts/build_standalone_feed.py` |
| SQL static validator | `scripts/validate_sql.py` |
| CSV → macro generator | `scripts/gen_segment_macro.py` |
| Apps Script that builds every sheet tab | `scripts/build_gsheet.gs` |
| Commit on branch `feat/blended-reporting-model` | 37 files, +4,638 |

The Metabase question's SQL **parses cleanly on Redshift** — the only error is
`relation "reporting.josiemaran_blended_performance" does not exist` (SQLSTATE
42P01, undefined_table, not 42601 syntax). It starts returning rows the moment
`dbt run` finishes.

---

## Step 1 · Push the branch and open the PR

I have no git credentials or `gh` CLI in this environment, so the commit exists
locally only.

```bash
cd bolt-josiemaran
git push -u origin feat/blended-reporting-model
gh pr create --fill --base main
```

The commit message is written as the PR body — it covers the ID-based
segmentation, the catalog-segment finding, the TikTok campaign-grain fix, and
which test is expected to fail.

## Step 2 · Run dbt

```bash
dbt deps
dbt run  --select tiktok_campaign_performance shopify_sales_by_segment \
                  facebook_catalog_segment_performance blended_performance
dbt test --select blended_performance tiktok_campaign_performance
```

`tiktok_campaign_performance` will **overwrite** the table you built by hand.
Two intentional differences: `revenue` reads `total_purchase_value` instead of
`total_complete_payment_rate` (that column is a rate, not a currency amount —
currently masked because every TikTok conversion is zero), and `atc` is renamed
`add_to_cart` to match every other model.

### One test is expected to FAIL

`assert_sephora_spend_has_catalog_segment` — more than 20% of trailing-30-day
Sephora spend has no catalog-segment feedback. It clears when the campaigns are
fixed (step 5), **not** by editing the test.

The other two should pass: `assert_no_unmapped_live_spend` (7-day window) and
`assert_no_null_campaign_id`.

## Step 3 · Check the question returns rows

Open [question 57484](https://metabase-superbolt.com/question/57484). Expect
**~640 rows**. Filter `report_level = 'Sephora Segment'`, `period_label =`
the most recent week, and compare — these were measured against the warehouse
on 2026-09-07 for `2026-W36`:

| `lookup_key` | spend | cs_purchases | cs_revenue | cs_roas |
|---|---|---|---|---|
| `Sephora Segment\|Sephora – Total\|All\|2026-W36` | 21,998.67 | 145 | 5,703.00 | 0.26 |
| `Sephora Segment\|Sephora US Traffic\|All\|2026-W36` | 16,444.38 | *(blank)* | *(blank)* | *(blank)* |
| `Sephora Segment\|Sephora CA Traffic\|All\|2026-W36` | 3,651.16 | *(blank)* | *(blank)* | *(blank)* |
| `Sephora Segment\|Sephora US Collab\|All\|2026-W36` | 852.15 | 106 | 4,104.00 | 4.82 |
| `Sephora Segment\|Sephora CA Collab\|All\|2026-W36` | 344.45 | 39 | 1,599.00 | 4.64 |
| `Sephora Segment\|Sephora @ Kohls\|All\|2026-W36` | 706.53 | *(blank)* | *(blank)* | *(blank)* |

If Collab shows ~4.8 / ~4.6 ROAS while Traffic shows blank, the ID mapping and
the catalog-segment join are both working. That contrast is the finding.

Lifetime, for reference: Google Overall $688,295 · Meta Overall $519,752 ·
Sephora US Traffic $202,850 · Sephora @ Kohls $281,044 · US Collab $72,422 ·
CA Traffic $66,321 · CA Collab $12,627.

## Step 4 · Connect the sheet

1. Rename `Sheet1` to **`feed`** (exact, lowercase) in the
   [reporting sheet](https://docs.google.com/spreadsheets/d/18-_3YywVlSxrz5jLUJ0-K-YRqkFWrpl0KB6m_iOMB_Y/edit).
2. Point the extension at question **57484**, target tab `feed`, header row in
   row 1, starting cell `A1`. Expect 38 columns, A:AL.
3. **Extensions → Apps Script**, paste all of `scripts/build_gsheet.gs`, Save,
   **Run ▸ `buildReport`**, authorise.

It creates `README`, `Health`, `Sephora WoW`, `DTC WoW`, `Monthly`, `Site`,
`Campaigns`, `Config` with every formula, number format and conditional format.
It never touches `feed`. Safe to re-run.

Read the two colours: **amber** = real Sephora spend, conversions unreported,
act on it. **Grey** = the data does not exist for that period, ignore it.

If the extension can't be used, the card has no template tags, so
`=IMPORTDATA(".../public/question/<uuid>.csv")` works off a public link — needs
sign-off, since that link is unauthenticated.

---

## Step 5 · The two account decisions

### Restore the catalog linkage on the SB traffic campaigns

`Sephora US Traffic` and `Sephora CA Traffic` — $20,096 in the latest week,
91% of Sephora spend — produce **no catalog-segment rows at all**, so their
Sephora purchases are unmeasurable. The legacy traffic campaigns they replaced
around 2026-08-25 *did* report, and the two collab campaigns still report
daily, so the pipeline is healthy. This reads as the catalog / CPAS linkage not
carrying over when the campaigns were rebuilt — worth confirming in Ads Manager.

Until then, Traffic can only be judged on clicks and CPC.

### Nothing to do about the unmapped spend

Nine campaigns hold $44,184 of trailing-30-day spend outside the mapping. All
nine stopped spending on or before **2026-08-27** — they are the predecessors
of the current structure, paused during the takeover. The mapping covers 100%
of spend from the week of 2026-08-31 onward.

That is why the health check and the dbt test use a **7-day** window: a 30-day
window would report the transition as a failure for a month. If you want the
retired campaigns in historical reporting, add their IDs to the CSV with their
own segment names and re-run `scripts/gen_segment_macro.py`.

---

## Adding a campaign later

```bash
# 1. add the row to seeds/campaign_segments.csv
# 2. regenerate the macro and the standalone card
python3 scripts/gen_segment_macro.py
python3 scripts/build_standalone_feed.py
python3 scripts/validate_sql.py metabase/generated/01_reporting_feed_standalone.sql
# 3. dbt run --select blended_performance
```

The generator validates the CSV — duplicate `(platform, campaign_id)`,
non-numeric IDs, a bad `business_line`, or `dtc_overall = true` on a non-DTC
row all fail loudly rather than producing a quietly wrong mapping.

Nothing in Metabase or the sheet needs touching: the segment appears as a new
row in the feed, and the Apps Script `CONFIG` decides whether to display it.

---

## Known constraints

- **DTC blended metrics start the week of 2026-07-27.** Shopify order history
  begins there — 19 orders the week before, 2,737 that week. August 2026 is the
  only complete month, so no blended MoM until October and no blended YoY this
  year. `data_valid` is FALSE before that and the sheet greys it.
- **Sephora is the opposite** — 18 months of catalog-segment history from
  2025-03, so Sephora MoM and YoY both work today.
- **Platform freshness varies; read it off the Health tab, do not assume it.**
  Google Ads was 8 days behind when this was first built and is level with
  Meta and Shopify as of 2026-09-08, so the lag is a sync condition, not a
  standing property — the `freshness` check reports it live per channel.
  Google's ~1,100% ROAS is
  correct: branded search is run to a deliberate 1,000% tROAS.
- **TikTok has no conversion data of any kind** — $292,756 spend, 145M
  impressions, zero conversions across the full history. Spend and delivery are
  real. The connector's conversion metric group needs switching on; the models
  need no change when it is.
- **21% of DTC orders are subscription renewals** and 78% are repeat purchases,
  so site revenue moves largely independently of this week's spend. Judge paid
  on new-customer CAC and % new orders.
- `bingads_*`, `pinterest_*` and `googleads_ad_performance` are
  `enabled = false` — not live, no table in the warehouse. Delete them if
  they're definitively not coming.

## Running dbt locally on the server

dbt is installed in an isolated venv at `/home/ubuntu/.dbt-venv` (dbt-core
1.12.4, dbt-redshift 1.11.1). It does not touch the existing
`dataengineering/venv` or `.venv`.

**Why local rather than triggering Fivetran:** Fivetran syncs the repo from
GitHub on its own cadence, so a transformation fired immediately after a push
runs against the PREVIOUS commit. Running dbt here uses the working tree as it
is, which removes that race entirely.

**One profiles.yml, one login, many clients — not one profile per repo.**
Every `bolt-<client>` repo on this box declares the SAME dbt profile name,
`bolt_blueprint` (it's a forked blueprint, not a distinct dbt project per
client), and the whole fleet sits on one Redshift cluster under one login —
confirmed by querying both `josiemaran` and `fabric` as the same warehouse
user. So `~/.dbt/profiles.yml` holds ONE profile with ONE set of credentials
and a `--target <client>` per client, not a separate file or profile per repo.

The target list is generated, not hand-written, because a repo's name is not
a reliable database name — `bolt-mate`'s database is `matethelabel`, not
`mate`. Regenerate after adding a new client repo:

```bash
python3 ~/python/dataengineering/.shared/gen_dbt_profile.py --databases=<comma-separated list from pg_database>
```

It resolves each repo slug against the real database list (exact match, or a
unique fuzzy match; anything ambiguous is flagged instead of guessed), and
never overwrites credentials already filled in.

**No default target, on purpose.** Every dbt command below must pass
`--target <client>` explicitly — there is no "forgot the flag, ran it against
someone else's database" failure mode.

The 14 private `superbolt-x` packages in `packages.yml` are declared with
HTTPS URLs. There is no HTTPS credential on this box, but there is an SSH key,
so rewrite the URLs for the command rather than editing `packages.yml`:

```bash
GIT_CONFIG_COUNT=1 \
GIT_CONFIG_KEY_0=url.git@github.com:.insteadOf \
GIT_CONFIG_VALUE_0=https://github.com/ \
/home/ubuntu/.dbt-venv/bin/dbt deps
```

**Still required:** host/user/password in `~/.dbt/profiles.yml` — three
placeholders, filled once, shared by every client target. Until they're
filled, `dbt parse` and `dbt deps` work; `dbt run`, `dbt seed` and `dbt test`
cannot connect.

Once credentials exist, the loop for a segment change on this client is:

```bash
/home/ubuntu/.dbt-venv/bin/dbt seed  --target josiemaran --select campaign_segments
/home/ubuntu/.dbt-venv/bin/dbt run   --target josiemaran --select +blended_performance
/home/ubuntu/.dbt-venv/bin/dbt test  --target josiemaran --select blended_performance
```

`dbt parse` is worth running on every change even without credentials — it
compiles every model and macro and validates all schema tests. It caught two
`accepted_values` lists that were stale after GA4 rows were added (`channel`
missing 'GA4', `segment` missing 'Unattributed Paid' and 'Other'), which no
amount of SQL-only linting would have found.

## Triggering Apps Script without edit access

Marketing can't run Apps Script themselves, and handing out a content-write
OAuth token to automate that was a bad trade (see the security discussion in
session history — write access to Apps Script is account-wide, not
project-scoped, and Google doesn't support service accounts for it). What
this uses instead: an **execution-only** grant. It can invoke a function
already deployed in this project; it cannot edit the project's code at all,
and it cannot touch any spreadsheet other than this one.

**How it's scoped, concretely:**

- The project's `appsscript.json` declares exactly three OAuth scopes:
  `spreadsheets.currentonly` (this spreadsheet only, not every sheet the
  authorizing account can reach), `script.external_request` (the Metabase
  call), `script.scriptapp` (trigger management).
- Deployed as **API Executable** (Deploy → New deployment), a deployment
  type with no path to `projects.updateContent` — content-write is a
  categorically different scope Google enforces at the API level, not a
  policy this setup merely follows.
- Verified empirically, not just by scope inspection: a content-write
  attempt with this token returns `403 ACCESS_TOKEN_SCOPE_INSUFFICIENT`,
  and so does a read attempt against a different (public) spreadsheet — the
  `currentonly` binding is actually enforced, confirmed against Google's
  live API, not assumed from the scope name.

**Credentials** live at `~/.config/gas-exec/` on the server — `oauth_client.json`
(the OAuth client from Google Cloud project `superbolt-agency-etl`) and
`tokens.json` (refresh token, from the one-time manual consent flow). Both
`chmod 600`, both outside any git repo. Never write either into this repo.

**To run something:**

```bash
python3 ~/python/dataengineering/.shared/gas_exec.py 18VE39XIFG5y7ZwVUeOwMCEC84izC7zoDOuUrQfaaz6RF3j30C5PjqPS6 refreshAndRebuild
```

(Script ID above is Josie Maran's — not secret on its own, it's inert without
the token.) Exits non-zero on a real failure, including a script-side
exception the Execution API reports as HTTP 200 with an `error` field — the
CLI checks for that explicitly rather than trusting the HTTP status alone.

**If this ever needs to be revoked:** whoever did the OAuth consent can pull
it from their Google Account → Security → Third-party access, independent of
rotating anything else. That kills `tokens.json`'s refresh token immediately;
getting it working again means redoing the manual consent flow from scratch.


---

# Budget Pacing & DoD Budgets

Two Gsheet tabs, four stacked-column charts each (Sephora US, CA, @ Kohl's, DTC):

- **Budget Pacing** — the month in progress. Past days are grey (actual spend),
  remaining days are colour (the client's forecast budget). Above each chart: the
  "spent X% of the monthly budget through Y% of the month" headline.
- **DoD Budgets** — the client's planned spend per day for a month, all in colour.
  Shows next month once it is budgeted, else the current one.

Data path: client budget sheet → `budget_forecast_to_redshift.py` (cron, 09:00 UTC,
lives in `josiemaran/` beside this repo) → `gsheet_raw.josie_maran_budget_forecast`
→ dbt `budget_pacing` (budget beside actual spend from `blended_performance`) →
Metabase card → feed tab → `build_pacing_tabs.gs` draws the charts.

## Deploying

**1. dbt.** `budget_pacing` reads `blended_performance`, which must already be built.
`--target josiemaran` is mandatory (there is no default target, on purpose), and dbt lives
in its own virtualenv. Built and tested 2026-10-07: 17 of 17 tests pass.

```bash
/home/ubuntu/.dbt-venv/bin/dbt run  --target josiemaran --select budget_pacing
/home/ubuntu/.dbt-venv/bin/dbt test --target josiemaran --select budget_pacing assert_budget_lines_mapped assert_budget_pacing_spend_ties_to_blended
```

`assert_budget_pacing_spend_ties_to_blended` proves the campaign → budget-line join
neither drops nor duplicates spend. If it fails, do not ship the charts.

**2. Metabase question.** Created: **57543**, "JM – Budget Pacing", in collection 4503
beside the feed. It runs `metabase/02_budget_pacing.sql` against the dbt table. If that
SQL changes, update the question to match. No template tags — which month shows is decided
in the sheet. (`metabase/generated/02_budget_pacing_standalone.sql` is only for wiring the
card up before dbt has built the table; it is no longer needed.)

**3. Apps Script.** In the existing project add a **second file** and paste
`scripts/build_pacing_tabs.gs`. `PACING_CARD_ID` is already set to 57543 (at `0` the new
tabs are simply skipped and the existing report is unaffected). Run `refreshAndRebuild`; the
daily trigger already calls it. If you pull the card with the Metabase extension instead,
name its tab `budget pacing @ <id>`. If the API Executable deployment is in use, deploy a new
version after pasting, or the execution-only grant will keep running the old code.

**4. Look at it once.** `scripts/test_sheet_tabs.py` runs the script in V8 against a
mock Sheets API, but it cannot show how Google draws the chart. To see the real thing
without opening the sheet, export a tab as a PDF and render it (the Drive export of a
single `gid` works with the service account); that is how the points below were found.
Checked in the real sheet on 2026-10-07: the bars are **stacked**, the day labels are
discrete (`10/1`, `10/2`…), the colours match the doc, and a chart edited in place on the
daily run keeps its ID and stays stacked.

**Why "Actual spend" is one grey series.** The first design gave every campaign a grey
"actual" twin and hid the twins from the legend with the `visibleInLegend` series option.
**Google ignores that option on a Sheets chart**: the legend listed all of them, 18 entries
across four rows on DTC. So the past days are one grey "Actual spend" series (the sum across
campaigns) and the legend is the campaigns plus that one entry (10 on DTC). The cost is that
the per-campaign split of past days is gone; the doc's greys had no legend, so they could not
be decoded. `actual_color` is still in the card and the seed but no longer used by the sheet.

**Axis labels follow the cells' number format**, not the chart's `vAxis.format` option, so the
data cells are formatted `$#,##0` (not `$#,##0.00`), or the axis reads `$5,000.00`.

## Using it

- **Month override** (cell B2 of either tab): type a month, e.g. `2026-09-01`, to look
  at another one. Blank follows the data. An unknown month is ignored, and says so.
- **Budget override** (the "Budget override" cell in each pacing block): the monthly
  budget defaults to the **sum of the daily budgets**. Type a figure to quote a
  nominal one instead (e.g. `95000`). It survives rebuilds. Do not use the client
  sheet's own "Total Budget" row — it leaves out NB PMax, so it understates DTC.
- **Actuals through** (row 2): how far the actuals really go. A day counts as actual only
  once it is **complete**, meaning the platform has synced a *later* day (that proves a sync
  happened after it ended). So early in the morning, before the first post-midnight sync
  lands, it can be two days back; that is correct, not a fault. If it is further behind, the
  feed is stale or a platform is late. Days past it show as forecast, never as $0.

## Adding a campaign

A budget line is one row of the client's budget sheet. Two things must know about a
new one — the loader (so it is read) and this mapping (so it is drawn):

```bash
# 1. budget_forecast_to_redshift.py: add the line to CAMPAIGN_DEFS (the loader alerts
#    #data-script-errors and refuses the tab until you do)
# 2. here: add a row to seeds/budget_campaign_map.csv. campaign_key must equal the
#    loader's key; platform + campaign_id say which spend belongs to it; colours and
#    stack_order say how it is drawn. A line with no live campaign yet can have a blank
#    campaign_id (TikTok Web did, before it launched). For a DTC line also set
#    spend_type (prospecting / mixed / brand / nonbrand) so it appears in the Gross
#    Sales vs Spend charts; leave it blank to keep it out (GMV Max is blank).
python3 scripts/gen_budget_map_macro.py
python3 scripts/build_sheet_cards.py
dbt run --select budget_pacing dtc_sales_vs_spend
```

If a budget line reaches the table without a mapping row, `assert_budget_lines_mapped`
fails — the chart would otherwise draw it with no colour and no label.

`seeds/budget_campaign_map.csv` is **not** `campaign_segments.csv`. Segments are the
client's reporting definition; mapping Lead Gen there would have moved $838 of
September spend into "Meta Overall" and "Paid DTC Overall" and changed numbers the
client already received.

## Known limits

- **Sale labels and the numbered markers** on the doc's October charts (Prime Day,
  Free Shipping, ①②③) are drawn by hand and are not part of these charts.
- **A stale feed** shows older numbers until the next refresh; "Actuals through" is the
  tell. A failed pacing refresh is toasted but does not stop the rest of the report.
- **Platform freshness is per platform.** A platform that syncs late shows forecast
  colour for the days it is missing while the others show grey.
- **Why a day must be complete to count.** A platform's latest synced day is usually still
  filling. Checked 2026-10-07: Sephora US for 10/6 read $1,705 early in the morning and $2,375
  once the rebuild caught up, while every earlier day moved by cents. Drawing that as a finished
  grey bar understated both the bar and the "% of budget spent" headline. The rule (the day
  before the platform's latest synced day, capped at yesterday) was checked by hiding today's
  rows and confirming it stops one day earlier. If a platform stops spending entirely, it
  stalls one day behind its last spend day and the days after stay forecast, not $0.


---

# Gross Sales vs Spend

One more tab, **Gross Sales vs Spend**, month to date, with the weekly doc's two Shopify
charts, one chart each, drawn as the doc draws them (a stack beside a stack for every day):

| Chart | Left axis | Right axis |
|---|---|---|
| **Gross Sales vs. paid spend** | New-customer + returning-customer gross sales (stacked) | Meta + Google + TikTok spend (stacked) |
| **Spend by type vs. new customers** | New customers (one column) | Prospecting + Mixed + Brand + Nonbrand spend (stacked) |

**How the pairs are drawn.** In a *stacked* column chart, series assigned to different axes are
drawn as separate stacks **side by side inside each day**, with the label centred under the pair.
The table is one row per day; some columns are on the left axis, the rest on the right. No
interleaving or other trick is needed.

**This was first built wrong, on an untested belief.** The first version said Sheets could not
draw this and split each doc chart into two charts. That had never been tried. A throwaway spike
on the live sheet (5 variants, from the real 9/18–9/27 data, rendered via a PDF export and
compared with the doc) showed the plain layout already gives the doc's chart, and also that:

- **Explicit axis ranges and a gridline count are honoured.** Each axis gets a "nice" maximum
  from its own tallest stack (`salesNiceMax_`), with the same five gridlines on both, so they
  line up as the doc's do: $0/$15K/$30K/$45K/$60K against $0/$1.25K/$2.5K/$3.75K/$5K.
  Left alone, the two axes pick unrelated scales and the gridlines do not align.
- **Axis labels follow the cells' number format**, so customers are a count and the rest are
  dollars with no decimals.
- **A series that is blank all month is dropped by Google itself** (TikTok today).
- **Not honoured: `visibleInLegend`** (see the pacing section). It is not used here.

**Density.** At month end that is 31 pairs, which is why the charts are 1,100px wide; today's
6 days look sparse by comparison. The day label sits centred under each pair, as in the doc.

**Month to date, on purpose.** The doc's version was a hand-picked 10 days (9/18–9/27),
split "Pre / Post Spend Adjustment" around one decision on 9/23. That was a one-off, so
the tab shows the month so far, through the last complete day. It follows the data (on the
1st it still shows the month that just closed) and cell B2 overrides the month. There is no
event-date feature, because how this chart evolves is not known yet.

Data path: `reporting.josiemaran_shopify_sales_by_segment` + `blended_performance` →
dbt `dtc_sales_vs_spend` → Metabase card `metabase/03_dtc_sales_vs_spend.sql` → feed tab
`dtc sales vs spend @ <id>` → `build_sales_tab.gs`.

## Deploying

```bash
/home/ubuntu/.dbt-venv/bin/dbt run  --target josiemaran --select dtc_sales_vs_spend
/home/ubuntu/.dbt-venv/bin/dbt test --target josiemaran --select dtc_sales_vs_spend assert_dtc_spend_is_classified assert_dtc_sales_vs_spend_ties_to_sources
```

Built and tested 2026-10-07. The Metabase question is created: **57544**, "JM – DTC Sales vs
Spend", in collection 4503. Add `scripts/build_sales_tab.gs` as a **third file** in the Apps
Script project **next to** `build_pacing_tabs.gs` (it needs that file's helpers).
`SALES_CARD_ID` is already set to 57544 (at `0` the tab is simply skipped). Then run
`refreshAndRebuild`.

## Keeping the tables fresh

`budget_pacing` and `dtc_sales_vs_spend` are dbt tables, so they are only as current as the last
dbt run that built them.

**dbt for Josie Maran runs in Fivetran Transformations (dbt Core)**: project `swooned_plaza`, repo
`bolt-josiemaran`, branch `main`. Its jobs are all `INTEGRATED`: each runs right after specific
connectors finish syncing, which works out to roughly every four hours.

**The existing jobs run SELECTED models, not the whole project, so a new model is not built until
it is added to a job.** Checked 2026-10-07: the 16:05 UTC run rebuilt `blended_performance` and
`shopify_sales_by_segment` but not the two new models, which kept their manual build from 13:21.
Remember this whenever a model is added to the repo.

**Job `confirm_pogo`, "JM budget pacing + sales vs spend (after blended_performance)"** builds them:

- Schedule: `INTEGRATED` after the job `legged_earplugs`, the one that rebuilds `blended_performance`
  (the table was rebuilt at 12:06:43 inside that job's 12:05:33-12:06:57 run). So the two models are
  rebuilt right after `blended_performance`, every cycle, and the sheet never sits a day behind.
- Steps: `dbt run --select budget_pacing dtc_sales_vs_spend`, then `dbt test --select` on both models
  and their four singular tests. A failing test fails the job.
- First run 2026-10-07 16:11 UTC (triggered by hand): SUCCEEDED in 2m34s, both tables rebuilt by Fivetran.
- It was created through the API, so **it exists only in Fivetran, not in this repo**. To change it:
  Fivetran, Transformations, josiemaran. To add another model, add it to the `--select` of the run
  step (and any test of it to the test step).

To check that a job built a table, compare its build time (dbt swaps the table in, so creation time
is the last build):

```sql
select relname, relcreationtime from pg_class_info
where relnamespace = (select oid from pg_namespace where nspname = 'reporting') and relkind = 'r'
  and relname in ('josiemaran_budget_pacing', 'josiemaran_dtc_sales_vs_spend', 'josiemaran_blended_performance');
```

**Failure alerting is a gap.** A failed job shows in Fivetran, but nothing posts it to Slack:
`fivetran/fivetran_transformations_alert.py` reads the legacy `/v1/dbt/projects` API, which does not
list this project (it returns 404), and neither it nor `fivetran_slack_alerts.py` is scheduled in the
crontab. The budget loader, by contrast, alerts `#data-script-errors` itself.

The loader that fills `gsheet_raw.josie_maran_budget_forecast` runs at 09:00 UTC, so a budget edit
reaches `budget_pacing` at the first cycle after that.

## What is counted, and why it differs from the DTC WoW report

- **Lead Gen is included**, as Prospecting. The doc's Meta bar and Prospecting bar include
  it (2026-09-27: $2,215 Meta Overall + $404 Lead Gen = $2,619; the chart reads ~$2,625).
  `campaign_segments.csv` leaves Lead Gen unmapped, so the DTC WoW report's "Paid DTC
  Overall" excludes it and **the two will not agree on Meta spend**. That is a gap in the
  existing report's definition, not something these charts introduce.
- **TikTok GMV Max is excluded.** Its revenue is TikTok Shop GMV, which never reaches
  Shopify; these charts compare spend with Shopify sales.
- **TikTok spend** shows only once a TikTok line with a `spend_type` (TikTok Web) has spend.
  A series that is blank or zero all month is dropped, and its axis stays configured by what is left.
- **TikTok's light blue is not sampled** from the doc (there are no TikTok bars in it to
  sample); it reuses the light blue of the pacing charts.
- **Spend is blank, not 0, on a day a platform has not synced.** Sales still show.

## If a test fails

- `assert_dtc_spend_is_classified`: a DTC campaign is in `campaign_segments.csv` but not in
  `budget_campaign_map.csv`, so its spend would vanish from these charts. Add it there.
- `assert_dtc_sales_vs_spend_ties_to_sources`: the model dropped or duplicated something, or
  the platform and type cuts disagree (a campaign with a platform but no `spend_type`).
