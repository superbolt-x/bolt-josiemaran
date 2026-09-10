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
