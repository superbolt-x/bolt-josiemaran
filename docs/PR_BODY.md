# Add GA4 as a fourth conversion source; Sunday-anchored weeks; slide-shaped sheet
## What this adds

**GA4 as a fourth conversion source** on `blended_performance` — `ga4_sessions`,
`ga4_purchases`, `ga4_revenue`, read straight from `ga4_raw.traffic_sources_session`
(no reporting model). Channel from `session_source_medium`:
`metaads / paidsocial` → Meta, `google / cpc` → Google, everything else → `Other`.
TikTok has no mapping — no DTC TikTok campaigns exist yet.

**Meta needed a detour.** Google's `session_campaign_id` *is* the campaign id.
Meta's is `<adset_id>_v2_sNN` — checked against the ad tables, the prefix matches
`adset_id` on 10,762 rows and `campaign_id` on zero. So Meta needs
`split_part(_,'_',1)` plus an adset→campaign lookup. Verified: no adset maps to two
campaigns. Resolves 99.2% of Meta sessions.

GA4 rows that resolve attach to the paid row, so `ga4_roas` works per segment.
Rows that don't become their own `channel='GA4'` rows via an anti-join. Disjoint
sets, so it reconciles exactly — week of 2026-08-31: 34,029 Other + 8,820 Google +
7,276 Meta + 1,372 Unattributed + 16 = **51,513 sessions**, matching the raw table.

Expect `paid_roas` and `ga4_roas` to disagree: Meta Overall is 0.73 GA4 ROAS that
week, Google Overall 4.06. One is view-through-windowed, the other last-non-direct
session. The model header says never to add them.

## Weeks

`week_start: 'Sunday'` is deliberate — the client asked for it and the packages
honour it. `jm_week_start()` now reads that var rather than hard-coding the anchor,
so flipping `dbt_project.yml` moves our derived weeks and the packages' together.
Without it, Redshift's `date_trunc('week', d)` returns the ISO Monday and the
blended table ends up with two sets of week dates — no error, every weekly number
silently halved.

The macro is only for the three sources that arrive **daily with no
`date_granularity`**: order-level Shopify, the Facebook catalog-segment EAV tables,
GA4 sessions. Anything already carrying `date_granularity` is read by **filtering
that column**. `date_trunc` survives only in the card's two date-range filters.

Verified against the warehouse: package weeks and all three derived weeks land on
the same Sundays (08-02 → 09-06).

## Report window

The card supplies 7 weeks / 3 months; the sheet reads the last 2 for KPI tables and
4 for charts. Changing the window is now a constant in the Apps Script, not a SQL
edit.

## Generated, not hand-edited

`metabase/01_reporting_feed.sql` now comes from `scripts/gen_reporting_feed.py`.
Every level emits 25 columns twice (week + month); hand-patching GA4 in matched the
week branch and missed the month branch on four of five levels, because the
surrounding text differs by `from wk` vs `from mo`. Symptom would have been GA4
absent from every MTD number with no error.

## Sheet layout matches the deck

Each slide gets its own block: metrics down the rows, two date columns + % change,
then a 4-period chart-data table. Five metric shapes across seven tabs.

Sephora Traffic deliberately carries no conversion rows — those campaigns emit no
catalog-segment data, so there is no honest figure, and blank rows would invite
someone to fill them from the wrong column.

## Left alone

Both TikTok models keep `total_complete_payment_rate as revenue` and `atc`.
`blended_performance` reads neither — it sources the base table and derives revenue
from `total_purchase_value` itself, so they cannot disagree.

## Also

Fixed a compile breaker from the `jm_reporting` → `reporting` rename (the
`facebook_performance_by_ad` source was missed). Fixed two compiler bugs found while
verifying: CTE namespacing rewriting inside string literals (would have made every
campaign `Unmapped` silently), and nested macro args not being bound (emitted SQL
referencing a column called `date_col`). Both now have `validate_sql.py` checks,
each verified by injecting the bug.

Run with `dbt run --select +blended_performance` — 3 models, no package rebuild.
