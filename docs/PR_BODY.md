Add blended reporting model with campaign-ID segments

## What this does

Builds the automated reporting stack for Josie Maran: a cross-channel blended
model, Sephora conversions from catalog segment actions, and a single Metabase
feed card (`JM – Reporting Feed`, [57484](https://metabase-superbolt.com/question/57484))
that the reporting Gsheet reads.

Segments are assigned by **campaign ID** (`seeds/campaign_segments.csv`, from the
reporting deck) rather than parsed from campaign names. The account was inherited
and carries three incompatible naming conventions, one objective spelled
`Traffic`/`traffic`/`Traffic-2`, and region as us/US/ca/CA/USA. Unmapped IDs
resolve to segment `Unmapped` and surface on the Health rows rather than being
folded into a total.

```
Google Overall + Meta Overall = Paid DTC Overall   (in_dtc_overall flag)
Sephora US/CA Traffic · Sephora US/CA Collab · Sephora @ Kohls
```

## New models

| Model | What |
|---|---|
| `blended_performance` | cross-channel fact table (Meta, Google, TikTok, Shopify) |
| `facebook_catalog_segment_performance` | Sephora conversions, pivoted out of the EAV raw tables |
| `tiktok_campaign_performance` | campaign grain, from the package base model |
| `shopify_sales_by_segment` | site sales carrying market + order_type |

**Why catalog segment actions matter.** Sephora sells on sephora.com, so purchases
fire on Sephora's pixel against Sephora's catalog segment — nothing lands in Meta's
own purchase columns or in Shopify. Read on `purchases`, the Sephora account shows
18 purchases on $566,802 of 2026 spend; on catalog segment actions it has driven
6,797 purchases and $274,382 since March 2025. The action types **nest**
(`omni_purchase` = web + in-store + app), so a naive `SUM` over `action_type`
returns 5,599,760 against a true 6,797 — the model pivots named types so that
mistake is unavailable downstream.

## Fixes

- **`tiktok_campaign_performance`** — `revenue` was `total_complete_payment_rate`,
  a rate, not a currency amount. Also reads campaign grain because the ad-grain
  join returns NULL `campaign_id` for both campaigns launched 2026-08-27
  ($9,507, all current TikTok spend), which made an ID join impossible.
- **`facebook_campaign_performance`** — the `account` CASE returned NULL for any
  account id outside the two hard-coded values.
- **`bingads_*`, `pinterest_*`, `googleads_ad_performance`** — set
  `enabled = false`; not live, no table in the warehouse.

`googleads_campaign_performance` keeps `conversions`/`conversions_value`. An
earlier draft remapped them on a 1.50x-of-store-orders reading; that ratio came
from a window including four months where Google was spending against Shopify
order data that had not yet synced. On August alone it is 0.24x store orders and
1,091% ROAS, matching the deliberate 1,000% tROAS.

## Tests

| Test | Expected |
|---|---|
| `assert_sephora_spend_has_catalog_segment` | **FAILS** — ~91% of live Sephora spend has no catalog feedback. Clears when the SB traffic campaigns are added to the catalog partnership, not by editing the test. |
| `assert_no_unmapped_live_spend` | passes (7-day window) |
| `assert_no_null_campaign_id` | passes |

Health and test windows are 7 days, not 30: the nine predecessors of the current
structure all stopped spending by 2026-08-27, so a 30-day window reports $44,184
of correctly-unmapped retired spend and fails through the whole transition. From
the week of 2026-08-31 the mapping covers 100% of spend.

## Tooling

- `scripts/gen_segment_macro.py` — CSV → macro, so the mapping needs no `dbt seed`
- `scripts/build_standalone_feed.py` — compiles the models into one query over the
  tables that exist today, so the sheet can be wired up before dbt runs
- `scripts/validate_sql.py` — static checks on the generated SQL
- `scripts/build_gsheet.gs` — Apps Script that builds every sheet tab

## What the mapping shows

Week of 2026-08-31: Traffic is $20,096 of $21,999 Sephora spend and produces **no**
catalog-segment conversions — the campaigns now defined as Traffic are the new SB
ones (no catalog linkage) plus TikTok (no conversion data of any kind). Collab is
$1,197 and produced **all 145** measured purchases, at 4.82 and 4.64 ROAS.

## Known constraint

DTC blended metrics are only valid from the week of 2026-07-27 — Shopify order
history begins there (19 orders the week before, 2,737 that week). August 2026 is
the only complete month, so no blended MoM until October and no blended YoY this
year. Sephora is the opposite: 18 months of catalog-segment history. Every card
carries a `data_valid` flag and the sheet greys those cells.

Full detail in `docs/RUNBOOK.md`.
