#!/usr/bin/env python3
"""
Generate metabase/01_reporting_feed.sql.

    python3 scripts/gen_reporting_feed.py

WHY THIS IS GENERATED
Every report level emits the same 25-column select twice — once from `wk`, once
from `mo`. Hand-maintaining the twins does not work: patching the card by hand
left the month branch of four levels without the GA4 columns while the week
branch had them, and the only symptom would have been GA4 silently missing from
every MTD number. Here each level's select list is written ONCE and both
branches are emitted from it, so they cannot diverge.

The 25 slots are positional and identical across levels. A level either sums a
slot or emits a typed NULL — nothing else.
"""
import pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
DEST = ROOT / "metabase" / "01_reporting_feed.sql"

WEEKS, MONTHS = 7, 4

# Typed NULLs, by slot name.
NULLS = {
    "spend":                "cast(null as double precision)",
    "impressions":          "cast(null as bigint)",
    "clicks":               "cast(null as double precision)",
    "paid_purchases":       "cast(null as double precision)",
    "paid_revenue":         "cast(null as double precision)",
    "cs_purchases":         "cast(null as double precision)",
    "cs_revenue":           "cast(null as double precision)",
    "cs_offline_purchases": "cast(null as double precision)",
    "cs_add_to_cart":       "cast(null as double precision)",
    "ga4_sessions":         "cast(null as bigint)",
    "ga4_purchases":        "cast(null as double precision)",
    "ga4_revenue":          "cast(null as double precision)",
    "site_orders":          "cast(null as bigint)",
    "site_first_orders":    "cast(null as bigint)",
    "site_new_customers":   "cast(null as bigint)",
    "site_gross_sales":     "cast(null as double precision)",
    "status":               "cast(null as varchar(8))",
    "detail":               "cast(null as varchar(256))",
}
METRIC_SLOTS = [s for s in NULLS if s not in ("status", "detail")]

LEVELS = [
    dict(
        cte="dtc_segment", label="DTC Segment",
        row_label="case when grouping(segment) = 1 then 'Paid DTC Overall'\n"
                  "             else segment end",
        market="'All'",
        is_rollup="grouping(segment)",
        read_metrics="case when grouping(segment) = 1 then 'blended_*' else 'paid_*' end",
        sums=["spend", "impressions", "clicks", "paid_purchases", "paid_revenue",
              "ga4_sessions", "ga4_purchases", "ga4_revenue",
              "site_orders", "site_first_orders", "site_new_customers", "site_gross_sales"],
        where="business_line = 'DTC'\n      and (in_dtc_overall or channel = 'Shopify')",
        group="grouping sets ((date), (date, segment))",
        having="sum(spend) > 0 or sum(shopify_orders) > 0",
        note="Paid DTC Overall = the Meta Overall + Google Overall campaign IDs,\n"
             "    -- not everything in the DTC account. GA4 is attached by campaign id.",
    ),
    dict(
        cte="sephora_segment", label="Sephora Segment",
        row_label="case when grouping(segment) = 1 and grouping(market) = 0\n"
                  "                  then 'Sephora – ' || market\n"
                  "             when grouping(segment) = 1 then 'Sephora – Total'\n"
                  "             else segment end",
        market="coalesce(market, 'All')",
        is_rollup="grouping(segment)",
        read_metrics="'cs_*'",
        sums=["spend", "impressions", "clicks",
              "cs_purchases", "cs_revenue", "cs_offline_purchases", "cs_add_to_cart"],
        where="business_line = 'Sephora'",
        group="grouping sets ((date), (date, market), (date, segment))",
        having="sum(spend) > 0",
        note="Meta AND TikTok. No ga4_* — GA4 measures josiemaran.com, and\n"
             "    -- Sephora traffic leaves the site, so GA4 never sees the purchase.",
    ),
    dict(
        cte="campaign", label="Campaign",
        row_label="campaign_id || '  ·  ' || coalesce(campaign_name, '(no name)')",
        market="market",
        is_rollup="0",
        read_metrics="case when business_line = 'Sephora' then 'cs_*' else 'paid_*' end",
        sums=["spend", "impressions", "clicks", "paid_purchases", "paid_revenue",
              "cs_purchases", "cs_revenue", "cs_offline_purchases", "cs_add_to_cart",
              "ga4_sessions", "ga4_purchases", "ga4_revenue"],
        where="channel not in ('Shopify', 'GA4')\n      and campaign_id is not null",
        group="campaign_id, campaign_name, market, date, business_line, segment",
        having="sum(spend) > 0",
        note="Both conversion families side by side; read_metrics says which applies.",
    ),
    dict(
        cte="ga4_channel", label="GA4 Channel",
        row_label="segment",
        market="'All'",
        is_rollup="0",
        read_metrics="'ga4_*'",
        sums=["ga4_sessions", "ga4_purchases", "ga4_revenue"],
        where="channel = 'GA4'",
        group="segment, date",
        having="sum(ga4_sessions) > 0",
        note="GA4 rows with no paid campaign to attach to: 'Other' (email, SMS,\n"
             "    -- organic, direct, affiliates) and 'Unattributed Paid'. Surfacing them\n"
             "    -- means total GA4 revenue reconciles to the raw table.",
    ),
    dict(
        cte="site", label="Site",
        row_label="coalesce(order_type, 'All')",
        market="coalesce(market, 'All')",
        is_rollup="grouping(order_type)",
        read_metrics="'site_*'",
        sums=["site_orders", "site_first_orders", "site_new_customers", "site_gross_sales"],
        where="channel = 'Shopify'",
        group="grouping sets ((date), (date, order_type), (date, market))",
        having="sum(shopify_orders) > 0",
        note="Web vs Subscription is the split that decides whether a blended\n"
             "    -- number means anything: 21% of orders are subscription renewals.",
    ),
]

SITE_SRC = {"site_orders": "shopify_orders", "site_first_orders": "shopify_first_orders",
            "site_new_customers": "shopify_new_customers", "site_gross_sales": "shopify_gross_sales"}


def branch(lv, src, grain):
    parts = [
        f"        '{lv['label']}'{' ' * max(1, 38 - len(lv['label']))}as report_level",
        f"        {lv['row_label']}                   as row_label",
        f"        {lv['market']}                                  as market",
        f"        '{grain}'                                  as grain",
        "        date                                    as period_start",
        f"        {lv['is_rollup']}                       as is_rollup",
        f"        {lv['read_metrics']} as read_metrics",
    ]
    for slot in METRIC_SLOTS:
        if slot in lv["sums"]:
            col = SITE_SRC.get(slot, slot)
            parts.append(f"        sum({col})".ljust(48) + f"as {slot}")
        else:
            parts.append(f"        {NULLS[slot]}".ljust(48) + f"as {slot}")
    parts.append("        " + NULLS["status"].ljust(40) + "as status")
    parts.append("        " + NULLS["detail"].ljust(40) + "as detail")
    return (
        "    select\n" + ",\n".join(parts) + "\n"
        f"    from {src}\n"
        f"    where {lv['where']}\n"
        f"    group by {lv['group']}\n"
        f"    having {lv['having']}\n"
    )


def level_cte(lv):
    return (
        f"{lv['cte']} as (\n\n"
        f"    -- {lv['note']}\n"
        + branch(lv, "wk", "week")
        + "\n    union all\n\n"
        + branch(lv, "mo", "month")
        + "\n    union all\n\n"
        + branch(lv, "md", "mtd")
        + "\n),"
    )


HEADER = """/* JM – Reporting Feed  ·  ONE card, every report level. Filter with report_level.

   GENERATED by scripts/gen_reporting_feed.py — do not hand-edit. Every level
   emits the same 25 columns twice, week and month; the generator writes each
   select list once so the twins cannot drift. Patching this by hand is how the
   month branch of four levels ended up without the GA4 columns.

   READ read_metrics (col G) FIRST — four conversion sources, none interchangeable:
     paid_*  platform-attributed (Meta/Google own pixel, view-through window)
     ga4_*   GA4 last-non-direct session attribution, by session source/medium
     cs_*    Sephora, via catalog segment actions — the ONLY place Sephora
             conversions exist (paid_purchases is ~0 for that whole business)
     site_*  what Shopify actually booked
   paid_roas and ga4_roas will disagree. Show both, never add them.

   GA4 channel mapping: 'metaads / paidsocial' -> Meta, 'google / cpc' -> Google,
   everything else -> 'Other'. TikTok has no mapping yet (no DTC campaigns).
   Google's session_campaign_id is the campaign id; Meta's is <adset_id>_v2_sNN,
   so it needs split_part + an adset->campaign lookup (99.2% resolves).

   Segments come from CAMPAIGN IDs (seeds/campaign_segments.csv), not names.
   Unmapped IDs -> 'Unmapped', reported on the Health rows, never in a total.

   data_valid=FALSE -> the metric rests on data that isn't there (DTC before
   2026-07-27, Sephora before 2025-03). Grey it; don't filter it out.
   has_catalog_feedback=FALSE -> real Sephora spend, conversions unreported. Amber.

   NO template tags on purpose: keeps the card usable by the Gsheet extension
   and as a public CSV. Source of truth: bolt-josiemaran/metabase/01_reporting_feed.sql */
with

wk as (
    /*  Both bounds use the SUNDAY anchor, matching week_start: 'Sunday'.

        `date_trunc('week', current_date)` returns the ISO MONDAY. On Tue 8 Sep
        that is Mon 7 Sep, so `date < '2026-09-07'` fails to exclude the
        Sunday-anchored week beginning 6 Sep — and the report showed a 3-day
        partial week as if it were complete. Spend read -65.5% WoW.

        (date_trunc('week', current_date + 1) - 1) gives the Sunday of the
        current week, so `<` excludes the week in progress.                  */
    select *
    from reporting.josiemaran_blended_performance
    where date_granularity = 'week'
      and date >= (date_trunc('week', current_date + 1) - 1)::date - interval '@@WEEKS@@ week'
      and date <  (date_trunc('week', current_date + 1) - 1)::date
),

mo as (
    select *
    from reporting.josiemaran_blended_performance
    where date_granularity = 'month'
      and date >= date_trunc('month', current_date) - interval '@@MONTHS@@ month'
      and date <  date_trunc('month', current_date)
),

md as (
    /*  Genuine month-to-date, on a LIKE-FOR-LIKE window.

        `mo` deliberately excludes the month in progress, so a tab called MTD
        was really showing the last two COMPLETE months — August beside July.
        And putting a partial September next to a whole August would have made
        the % change meaningless anyway (7 days against 31).

        So MTD is built from day rows instead: this month through the last
        COMPLETE day (current_date - 1; today is still filling), and the same
        number of days of the previous month. Both rows are stamped with their
        own month start, so the sheet's newest/previous pair reads Sep 1-7 vs
        Aug 1-7 — two windows of equal length.

        On the 1st of a month the current window is empty, which is correct:
        there is no month-to-date yet.

        Aggregating from day grain is safe here because every ratio in this card
        is computed from summed numerators and denominators further down, never
        averaged from a pre-computed rate.                                    */
    select
        channel,
        segment,
        business_line,
        in_dtc_overall,
        market,
        order_type,
        campaign_id,
        campaign_name,
        date_trunc('month', date)::date         as date,
        'mtd'                                   as date_granularity,
        spend,
        impressions,
        clicks,
        paid_purchases,
        paid_revenue,
        paid_add_to_cart,
        cs_purchases,
        cs_revenue,
        cs_offline_purchases,
        cs_add_to_cart,
        ga4_sessions,
        ga4_purchases,
        ga4_revenue,
        shopify_orders,
        shopify_first_orders,
        shopify_repeat_orders,
        shopify_new_customers,
        shopify_gross_sales,
        shopify_total_sales,
        shopify_discounts
    from reporting.josiemaran_blended_performance
    where date_granularity = 'day'
      and (
              (    date >= date_trunc('month', current_date)::date
               and date <= current_date - 1 )
           or (    date >= date_trunc('month', current_date - interval '1 month')::date
               and date <= date_trunc('month', current_date - interval '1 month')::date
                           + (date_part(day, current_date - 1)::int - 1) )
          )
),

""".replace("@@WEEKS@@", str(WEEKS)).replace("@@MONTHS@@", str(MONTHS))

HEALTH = """health_freshness as (
    select
        channel                                 as subject,
        'freshness'                             as check_name,
        max(date)::varchar || ' · '
            || datediff(day, max(date), current_date)::varchar || 'd behind' as detail,
        case when datediff(day, max(date), current_date) > 3 then 'FAIL' else 'OK' end as status
    from reporting.josiemaran_blended_performance
    where date_granularity = 'day'
    group by 1
),

health_catalog as (
    select
        segment                                 as subject,
        'catalog-feedback'                      as check_name,
        round(100.0 * sum(case when coalesce(cs_purchases,0) = 0 then spend else 0 end)
                    / nullif(sum(spend),0), 1)::varchar || '% of $'
            || round(sum(spend))::varchar || ' unmeasured'  as detail,
        case when sum(case when coalesce(cs_purchases,0) = 0 then spend else 0 end)
                / nullif(sum(spend),0) > 0.20 then 'FAIL' else 'OK' end as status
    from reporting.josiemaran_blended_performance
    where date_granularity = 'day' and business_line = 'Sephora'
      and date >= dateadd(day, -30, current_date)
    group by 1
),

health_mapping as (
    -- 7-day window on purpose: the nine predecessors of the current structure
    -- all stopped spending by 2026-08-27, so a 30-day window reports ~$44k of
    -- correctly-unmapped retired spend and fails through the whole transition.
    select
        'Unmapped campaign IDs (7d)'            as subject,
        'mapping'                               as check_name,
        '$' || round(sum(case when segment = 'Unmapped' then spend else 0 end))::varchar
            || ' of $' || round(sum(spend))::varchar
            || ' · ' || count(distinct case when segment = 'Unmapped' then campaign_id end)::varchar
            || ' campaign(s)'                   as detail,
        case when sum(case when segment = 'Unmapped' then spend else 0 end) > 500
             then 'FAIL' else 'OK' end          as status
    from reporting.josiemaran_blended_performance
    where date_granularity = 'day' and channel not in ('Shopify', 'GA4')
      and date >= dateadd(day, -7, current_date)

    union all

    select
        'NULL campaign_id (7d)', 'mapping',
        '$' || round(sum(case when campaign_id is null then spend else 0 end))::varchar
            || ' of $' || round(sum(spend))::varchar,
        case when sum(case when campaign_id is null then spend else 0 end) > 0
             then 'FAIL' else 'OK' end
    from reporting.josiemaran_blended_performance
    where date_granularity = 'day' and channel not in ('Shopify', 'GA4')
      and date >= dateadd(day, -7, current_date)
),

health_ga4 as (
    -- GA4 revenue that attached to no paid campaign, as a share of all GA4
    -- revenue. High is normal (email/SMS/organic are most of it); a sudden
    -- jump means the Meta adset->campaign lookup has started failing.
    select
        'GA4 unattributed share (7d)'           as subject,
        'ga4'                                   as check_name,
        round(100.0 * sum(case when segment = 'Unattributed Paid' then ga4_revenue else 0 end)
                    / nullif(sum(ga4_revenue), 0), 1)::varchar || '% of paid-source GA4 revenue'
                                                as detail,
        case when sum(case when segment = 'Unattributed Paid' then ga4_revenue else 0 end)
                / nullif(sum(ga4_revenue), 0) > 0.15 then 'FAIL' else 'OK' end as status
    from reporting.josiemaran_blended_performance
    where date_granularity = 'day' and channel = 'GA4'
      and date >= dateadd(day, -7, current_date)
),

health_zero as (
    select
        business_line || ' – ' || channel        as subject,
        'zero-conversion'                        as check_name,
        '$' || round(sum(spend))::varchar || ' · '
            || round(sum(coalesce(paid_purchases,0)) + sum(coalesce(cs_purchases,0)))::varchar
            || ' conversions (30d)'              as detail,
        case when sum(spend) > 1000
              and sum(coalesce(paid_purchases,0)) + sum(coalesce(cs_purchases,0)) = 0
             then 'FAIL' else 'OK' end           as status
    from reporting.josiemaran_blended_performance
    where date_granularity = 'day' and channel not in ('Shopify', 'GA4')
      and date >= dateadd(day, -30, current_date)
    group by 1
),

health as (
    select
        'Health'                                as report_level,
        check_name || ': ' || subject           as row_label,
        'All'                                   as market,
        'n/a'                                   as grain,
        current_date                            as period_start,
        0                                       as is_rollup,
        'status'                                as read_metrics,
@@NULLS@@,
        status,
        detail
    from (
        select * from health_freshness
        union all select * from health_catalog
        union all select * from health_mapping
        union all select * from health_ga4
        union all select * from health_zero
    ) h
),

""".replace("@@NULLS@@", ",\n".join(f"        {NULLS[s]}".ljust(48) + f"as {s}" for s in METRIC_SLOTS))

FINAL = """unioned as (
@@UNION@@
)

select
    report_level,
    row_label,
    market,
    grain,
    -- Week label is the START DATE, not the ISO week number. Deck comment:
    -- "Please pull in the data for this slide to match the dates presented.
    --  The client views data from Sunday - Saturday."
    -- ISO numbering made this ambiguous: 2026-08-30 is a Sunday whose ISO week
    -- is 35 (Mon 24 - Sun 30), so the week STARTING 08-30 labelled itself
    -- "2026-W35" and read as the week before. The deck calls it 8/30/2026.
    case grain when 'week'  then to_char(period_start, 'FMMM/FMDD/YYYY')
               when 'month' then to_char(period_start, 'YYYY-MM')
               -- both MTD rows cover days 1..n, so one suffix describes each
               when 'mtd'   then to_char(period_start, 'FMMon')
                                 || ' 1-' || date_part(day, current_date - 1)::int::varchar
               else '' end                                      as period_label,
    period_start,
    read_metrics,

    report_level || '|' || row_label || '|' || market || '|' || grain || '|' ||
        -- lookup_key uses ISO dates, NOT the display label. Google Sheets
        -- auto-parses '2026-08' and '8/23/2026' into date serials on write, so
        -- a sheet formula rebuilding the key from a header cell produced
        -- '...|46235' and matched nothing — every MTD metric came back blank.
        -- ISO is what TEXT(cell,"yyyy-mm-dd") yields on the sheet side, so the
        -- two agree whether Sheets stored the header as text or as a date.
        case grain when 'week'  then to_char(period_start, 'YYYY-MM-DD')
                   when 'month' then to_char(period_start, 'YYYY-MM')
                   when 'mtd'   then to_char(period_start, 'YYYY-MM')
                   else '' end                                  as lookup_key,

    -- ── Delivery ───────────────────────────────────────────────────────────
    round(spend, 2)                                             as spend,
    impressions,
    round(clicks, 0)                                            as clicks,
    case when impressions > 0 then round(spend / impressions * 1000, 2) end     as cpm,
    case when impressions > 0 then round(clicks::numeric / impressions, 4) end  as ctr,
    case when clicks      > 0 then round(spend / clicks, 2) end                 as cpc,

    -- ── Platform-attributed ────────────────────────────────────────────────
    round(paid_purchases, 0)                                    as paid_purchases,
    round(paid_revenue, 2)                                       as paid_revenue,
    case when spend          > 0 then round(paid_revenue / spend, 2) end        as paid_roas,
    case when paid_purchases > 0 then round(spend / paid_purchases, 2) end      as paid_cpa,
    case when clicks         > 0 then round(paid_purchases::numeric / clicks, 4) end as paid_cvr,
    case when paid_purchases > 0 then round(paid_revenue / paid_purchases, 2) end as paid_aov,

    -- ── GA4 ────────────────────────────────────────────────────────────────
    ga4_sessions,
    round(ga4_purchases, 0)                                      as ga4_purchases,
    round(ga4_revenue, 2)                                        as ga4_revenue,
    case when spend         > 0 then round(ga4_revenue / spend, 2) end          as ga4_roas,
    case when ga4_purchases > 0 then round(spend / ga4_purchases, 2) end        as ga4_cpa,
    case when ga4_purchases > 0 then round(ga4_revenue / ga4_purchases, 2) end  as ga4_aov,
    case when ga4_sessions  > 0 then round(ga4_purchases::numeric / ga4_sessions, 4) end as ga4_cvr,

    -- ── Sephora catalog segment ────────────────────────────────────────────
    round(cs_purchases, 0)                                       as cs_purchases,
    round(cs_revenue, 2)                                         as cs_revenue,
    case when spend        > 0 then round(cs_revenue / spend, 2) end            as cs_roas,
    case when cs_purchases > 0 then round(spend / cs_purchases, 2) end          as cs_cpa,
    case when cs_purchases > 0 then round(cs_revenue / cs_purchases, 2) end     as cs_aov,
    case when clicks       > 0 then round(cs_purchases::numeric / clicks, 4) end as cs_cvr,
    round(cs_add_to_cart, 0)                                     as cs_add_to_cart,
    round(cs_offline_purchases, 0)                               as cs_instore_purchases,
    case when cs_purchases > 0
         then round(cs_offline_purchases::numeric / cs_purchases, 4) end        as pct_instore,

    -- ── Site ───────────────────────────────────────────────────────────────
    site_orders,
    site_first_orders,
    site_new_customers,
    round(site_gross_sales, 2)                                   as site_gross_sales,
    case when site_orders > 0 then round(site_gross_sales / site_orders, 2) end            as aov,
    case when site_orders > 0 then round(site_first_orders::numeric / site_orders, 4) end  as pct_new,

    -- ── Blended: rollup rows only ──────────────────────────────────────────
    case when is_rollup = 1 and spend > 0 and site_gross_sales > 0
         then round(site_gross_sales / spend, 2) end              as blended_roas,
    case when is_rollup = 1 and spend > 0 and site_new_customers > 0
         then round(spend / site_new_customers, 2) end            as blended_cac,

    -- ── Flags ──────────────────────────────────────────────────────────────
    case
        when report_level = 'Health'          then true
        when report_level = 'Sephora Segment' then period_start >= '2025-03-01'
        when report_level = 'GA4 Channel'     then period_start >= '2024-08-17'
        when grain in ('month', 'mtd')         then period_start >= '2026-08-01'
        else period_start >= '2026-07-27'
    end                                                          as data_valid,

    case when read_metrics = 'cs_*'
         then coalesce(cs_purchases, 0) > 0 or coalesce(cs_add_to_cart, 0) > 0
    end                                                          as has_catalog_feedback,

    status,
    detail

from unioned
order by
    case report_level when 'Health' then 0 when 'DTC Segment' then 1
         when 'Sephora Segment' then 2 when 'GA4 Channel' then 3
         when 'Site' then 4 else 5 end,
    period_start desc,
    is_rollup desc,
    spend desc nulls last,
    row_label
""".replace("@@UNION@@", "\n    union all ".join(
    ["    select * from " + LEVELS[0]["cte"]]
    + ["select * from " + l["cte"] for l in LEVELS[1:]]
    + ["select * from health"]
))


def main():
    sql = HEADER + "\n\n".join(level_cte(l) for l in LEVELS) + "\n\n" + HEALTH + FINAL
    DEST.write_text(sql)
    n_cols = 7 + len(METRIC_SLOTS) + 2
    print(f"wrote {DEST.relative_to(ROOT)}  ({len(sql):,} chars, {sql.count(chr(10)):,} lines)")
    print(f"levels: {', '.join(l['cte'] for l in LEVELS)} + health")
    print(f"branch width: {n_cols} columns, week+month for every level")


if __name__ == "__main__":
    main()
