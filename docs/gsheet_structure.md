# Josie Maran — Automated Reporting Gsheet

Target: [Josie Maran - Automated Reporting - MCP Version](https://docs.google.com/spreadsheets/d/18-_3YywVlSxrz5jLUJ0-K-YRqkFWrpl0KB6m_iOMB_Y/edit)

## One Metabase connection

**`JM – Reporting Feed`** → one tab called `feed`. That is the only Metabase
question the extension connects to. Every report tab is built from it with
`QUERY()` and `INDEX`+`MATCH`.

The feed is long in the dimensions and wide in the metrics — the shape both
sheet techniques want. ~**652 rows × 38 columns** at current volumes:

| `report_level` | Rows | Grain | Read |
|---|---|---|---|
| `Sephora Segment` | 143 | week ×13 | `cs_*` |
| `DTC Channel` | 156 | week ×13 | `paid_*` / `site_*` / `blended_*` |
| `Business` | 144 | month ×18 | mixed — see `read_metrics` |
| `Campaign` | 130 | week ×9 | `cs_*` or `paid_*` |
| `Site` | 65 | week ×13 | `site_*` |
| `Health` | 14 | none | `status` + `detail` |

Six cards split by level are kept in `metabase/split_alternative/` if the feed
ever needs breaking up — but at 652 rows it does not.

## Column map

```
A  report_level      I  spend           O  paid_purchases   S  cs_purchases          AA site_orders          AG blended_roas
B  row_label         J  impressions     P  paid_revenue     T  cs_revenue            AB site_first_orders    AH blended_cac
C  market            K  clicks          Q  paid_roas        U  cs_roas               AC site_new_customers   AI data_valid
D  grain             L  cpm             R  paid_cpa         V  cs_cpa                AD site_gross_sales     AJ has_catalog_feedback
E  period_label      M  ctr                              W  cs_aov                AE aov                  AK status
F  period_start      N  cpc                              X  cs_add_to_cart        AF pct_new               AL detail
G  read_metrics                                          Y  cs_instore_purchases
H  lookup_key                                            Z  pct_instore
```

`lookup_key` (col **H**) = `report_level|row_label|market|period_label`

## The two columns to read before any metric

**`read_metrics` (G)** names the metric family that applies to that row. The two
businesses do not share a conversion source:

- `cs_*` — Sephora. Converts on **Sephora's** pixel via catalog segment.
  `paid_purchases` is ~0 for this whole business (18 purchases on $566,802 of
  2026 spend) and Shopify never sees the order.
- `paid_*` — DTC platform-attributed (Meta / Google own pixel).
- `site_*` — JM.com actuals from Shopify.
- `blended_*` — DTC spend ÷ Shopify revenue. Rollup rows only.

Putting a `cs_*` number next to a `paid_*` number and calling it "Meta" is the
mistake the whole model exists to prevent.

**`data_valid` (AI)** FALSE means the row's headline metric rests on data that
isn't there — DTC/Site before the week of 2026-07-27, Sephora before 2025-03.
Grey those cells; don't filter them out. A visible gap is the point.

**`has_catalog_feedback` (AJ)** Sephora rows only. FALSE = real spend,
unreported conversions. Amber, not grey — that is spend to act on.

---

## Tabs

| Tab | Built with | Contents |
|---|---|---|
| `feed` | extension | The one connection. Never edited, sorted or formatted. |
| `Sephora WoW` | INDEX+MATCH | US/CA Traffic + Collab, weeks across |
| `DTC WoW` | INDEX+MATCH | Blended DTC, Meta, Google, Shopify |
| `Monthly` | INDEX+MATCH | Business level, MoM / YoY |
| `Campaigns` | QUERY | Flat, sortable, filterable |
| `Site` | INDEX+MATCH | Web vs Subscription |
| `Health` | QUERY | 14 rows, pinned at the top of the report |
| `Config` | typed | Row order, display names, targets |
| `README` | typed | Copy from the bottom of this doc |

### Pattern A — `QUERY()` for flat tables

`Campaigns` tab, whole thing in one cell:

```
=QUERY(feed!$A:$AL,
  "select B, C, I, S, T, U, V, O, P, Q, R
   where A = 'Campaign' and E = '"&$B$1&"'
   order by I desc
   label B 'Campaign', C 'Market', I 'Spend', S 'cs purch', T 'cs rev', U 'cs ROAS',
         V 'cs CPA', O 'paid purch', P 'paid rev', Q 'paid ROAS', R 'paid CPA'", 1)
```

`Health` tab:

```
=QUERY(feed!$A:$AL, "select B, AK, AL where A = 'Health' order by AK desc", 0)
```

`QUERY` uses column letters, so it breaks if columns move. Keep the feed's
`select` list stable — that's why derived metrics are computed once at the end
of the card rather than per branch.

### Pattern B — `INDEX`+`MATCH` for the WoW grids

`Sephora WoW`:

```
A1  Market:            B1  [All ▼]        (All, US, CA — data validation)
A2  Data through:      B2  =MAX(FILTER(feed!$F:$F, feed!$A:$A="Sephora Segment"))
A3  Health:            B3  =COUNTIF(feed!$AK:$AK,"FAIL")&" checks failing"

A5  ── SPEND ──
A6  Segment    B6..H6 = week labels, most recent left    I6 = WoW %    J6 = 4wk avg
A7..A13        =Config!B2:B8
```

Week header, computed not typed:

```
B6:  =IFERROR(INDEX(SORT(UNIQUE(FILTER(feed!$E:$E,
        feed!$A:$A="Sephora Segment", feed!$D:$D="week")),1,FALSE), COLUMN()-1), "")
```

Body cell — the pattern for every metric block:

```
B7:  =IFERROR(INDEX(feed!$A:$AL,
                    MATCH("Sephora Segment|"&$A7&"|"&$B$1&"|"&B$6, feed!$H:$H, 0),
                    MATCH("spend", feed!$1:$1, 0)), "")
```

Two `MATCH`es — row by `lookup_key`, column **by header name**. Change the
metric by changing one string: `"cs_roas"`, `"cs_cpa"`, `"pct_instore"`. Unlike
`QUERY`, this survives a column being added or reordered in the card.

`I7` (WoW): `=IFERROR(B7/C7-1,"")` · `J7` (4-week avg): `=IFERROR(AVERAGE(C7:F7),"")`

Metric blocks for `Sephora WoW`: **spend · cs_purchases · cs_revenue · cs_roas ·
cs_cpa · pct_instore · cpc · ctr**. Note what is absent — no `paid_roas`, no
`blended_roas`. Neither applies to this business.

For `DTC WoW`, swap the level to `"DTC Channel"` and use **spend ·
paid_purchases · paid_roas · paid_cpa · site_orders · site_new_customers ·
blended_cac · blended_roas · aov · pct_new**.

For `Monthly`, level `"Business"` and `period_label` in `YYYY-MM`.

### Conditional formats — two colours, two meanings

Amber on Sephora blocks, custom formula:

```
=INDEX(feed!$AJ:$AJ, MATCH("Sephora Segment|"&$A7&"|"&$B$1&"|"&B$6, feed!$H:$H, 0)) = FALSE
```

Grey on DTC blended blocks:

```
=INDEX(feed!$AI:$AI, MATCH("DTC Channel|"&$A7&"|All|"&B$6, feed!$H:$H, 0)) = FALSE
```

Amber = real spend, unreported conversions, act on it. Grey = history that does
not exist yet, ignore it.

### `Config`

| A `row_label` | B `display_name` | C `show` | D `target` | E `level` |
|---|---|---|---|---|
| `Sephora – Total` | Sephora — Total | TRUE | | Sephora Segment |
| `US Collab` | US Collab (DPA) | TRUE | 1.50 | Sephora Segment |
| `CA Collab` | CA Collab (DPA) | TRUE | 2.50 | Sephora Segment |
| `US Traffic` | US Traffic | TRUE | | Sephora Segment |
| `CA Traffic` | CA Traffic | TRUE | | Sephora Segment |
| `Kohls Traffic` | Sephora @ Kohl's | TRUE | | Sephora Segment |
| `Blended DTC` | Blended DTC | TRUE | 3.50 | DTC Channel |
| `Meta` | Meta — DTC | TRUE | 2.50 | DTC Channel |
| `Google` | Google — DTC | TRUE | 10.00 | DTC Channel |
| `Shopify` | Shopify (site) | TRUE | | DTC Channel |

Column A must match the feed's `row_label` exactly. Row order here drives row
order everywhere. Collab is listed **above** Traffic deliberately — it is 7.5%
of Sephora spend and ~98% of its purchases.

---

## If the extension is unavailable

The card carries **no template tags**, so it also works as a plain public CSV:

```
=IMPORTDATA("https://metabase-superbolt.com/public/question/<UUID>.csv")
```

Refreshes about hourly, no auth. Needs sign-off — a public link is
unauthenticated; aggregate spend and revenue, no PII, but rotate the UUID if the
sheet's audience changes. An Apps Script + `POST /api/card/:id/query/csv`
variant is the authenticated fallback.

Parameter-free is also why market and period selection live in the sheet (`B1`)
rather than in Metabase.

---

## What to put in the README tab

> **Sephora and DTC are measured differently. Never mix them.** Check column G
> (`read_metrics`) before reading any number. Sephora sells on sephora.com — the
> purchase fires on Sephora's pixel against Sephora's catalog segment, so it
> produces no Shopify order and no row in Meta's own `purchases` column. On the
> standard purchase column the Sephora account shows 18 purchases on $566,802 of
> 2026 spend; on catalog segment actions it has driven 6,797 purchases and
> $274,382 since March 2025.
>
> **Collab and Traffic must never be averaged.** Lifetime: US Traffic
> $1,460,035 → 0.04 ROAS ($937 CPA). US Collab $72,422 → 1.14 ROAS ($36 CPA).
> CA Collab $12,627 → 2.93 ROAS ($14 CPA). Collab spends 4.8% of Traffic's
> budget for 60% more purchases. In the week of 2026-08-31 it was 7.5% of
> Sephora spend and 145 of 148 purchases.
>
> **Amber cells = real spend, unreported conversions.** The new
> `SB - US/CA - Sephora … Traffic` campaigns replaced the legacy traffic
> campaigns around 2026-08-25 and emit no catalog-segment rows, while carrying
> ~92% of live Sephora spend. The legacy collab campaigns still report daily, so
> the pipeline is healthy — this is a campaign-setup gap. Kohl's traffic and the
> retired Engagement campaign have never emitted any ($354,678 lifetime).
>
> **62% of US Traffic's conversions are in store**, vs 7% of US Collab's.
> Traffic drives footfall, collab drives sephora.com. Judging traffic on online
> ROAS alone understates it — though 0.04 is still 0.04.
>
> **DTC blended metrics start the week of 2026-07-27 (grey before that).**
> Shopify order history begins there: 19 orders in the week of 07-20, then 2,737
> in the week of 07-27. August 2026 is the only complete month, so no blended
> MoM until October and no blended YoY this year. Paid-only DTC goes back
> further — Meta to 2023-07, Google to 2024-08. Sephora is the opposite: 18
> months of catalog-segment history, so Sephora MoM and YoY both work today.
>
> **21% of DTC orders are subscription renewals** (4,226 of 19,636, $232,177)
> and 78% of orders are repeat purchases. Site revenue moves largely
> independently of this week's spend. Against the plan's 70 New / 20 Engaged /
> 10 Existing target, judge paid on **new-customer CAC** and **% new orders**,
> not blended ROAS.
>
> **Google Ads runs ~8 days behind.** Check the Health tab before comparing
> Google to another channel in the current week. Google's ~1,100% ROAS is
> correct — branded search is run to a deliberate 1,000% tROAS.
>
> **Three campaign naming conventions are live** — tagged `plat:…`, new
> `SB - …`, legacy `BD - …`. The dbt macros handle all three. A campaign
> matching none lands in `Unclassified` and shows up on the Health tab.
