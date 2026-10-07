{{ config (
    alias = target.database + '_dtc_sales_vs_spend'
)}}

/*
════════════════════════════════════════════════════════════════════════════════
  josiemaran_dtc_sales_vs_spend
════════════════════════════════════════════════════════════════════════════════

  GRAIN  one row per date (complete days only, today excluded)

  What Shopify booked each day beside what DTC paid media spent, for the two
  charts in the weekly doc: "Gross Sales vs. paid spend" and "Spend by type vs.
  new customers".

    Shopify   new_customer_gross_sales  gross sales from customers' FIRST orders
              returning_customer_gross_sales  gross sales from repeat orders
              new_customers             customers placing their first order
              (all markets and order types summed, which is what the doc shows)

    Spend     by platform  spend_meta / spend_google / spend_tiktok
              by type      spend_prospecting / spend_mixed / spend_brand /
                           spend_nonbrand
              Both are the same spend cut two ways, so each set sums to the same
              total. NULL, not 0, on a day the platform has not synced yet.

  ── Which spend counts ──────────────────────────────────────────────────────
  A campaign counts when its budget line has a spend_type in
  seeds/budget_campaign_map.csv. That is deliberately NOT blended_performance's
  `in_dtc_overall`: the doc's Meta bar and its "Prospecting" bar include the Lead
  Gen campaign (checked: 2026-09-27 is $2,215 Meta Overall + $404 Lead Gen = $2,619,
  the chart reads ~$2,625), and Lead Gen is unmapped in campaign_segments.csv, so
  `in_dtc_overall` leaves it out. Segments are the client's reporting definition;
  this chart's definition is the doc's.

  TikTok GMV Max has no spend_type and is therefore out. Its revenue is TikTok Shop
  GMV, which never reaches Shopify, so putting its spend next to Shopify sales
  would compare spend from one order system with revenue from another. The doc's
  charts leave it out too. TikTok Web, when it launches, is typed `prospecting`
  and will appear in spend_tiktok and in Prospecting with no change here.

  ── Types ───────────────────────────────────────────────────────────────────
    prospecting  Meta Prospecting Adv+ and Lead Gen
    mixed        Meta Retargeting (OG ASC): the legacy campaign that mixes
                 retargeting and reactivation, hence the doc's "Mixed"
    brand        Google US PMax Branded, US Branded Search, CA Branded Search
    nonbrand     Google NB PMax

  ── Actuals per platform ────────────────────────────────────────────────────
  Same rule as budget_pacing: a platform's spend counts through the EARLIER of its
  most recent synced day and yesterday in the business timezone. A late platform
  therefore leaves a gap, never a $0.

  Spend history is read from blended_performance, so it goes as far back as
  Shopify's does here; the Gsheet only draws the current month.
*/

with

today as (

    -- The calendar date in the business timezone, from the dbt_project.yml var
    -- time_zone. getdate returns UTC, which is already "tomorrow" for the last
    -- four evening hours of an Eastern day.
    select convert_timezone('{{ var("time_zone", "US/Eastern") }}', getdate())::date as today_local

),

shopify_daily as (

    select
        date,
        sum(first_order_gross_sales)    as new_customer_gross_sales,
        sum(repeat_order_gross_sales)   as returning_customer_gross_sales,
        sum(gross_sales)                as gross_sales,
        sum(new_customers)              as new_customers
    from {{ ref('shopify_sales_by_segment') }}
    where date_granularity = 'day'
      and date <= (select today_local from today) - 1
    group by 1

),

spend_rows as (

    select
        lower(channel)      as platform,
        campaign_id,
        segment,
        date,
        sum(spend)          as spend
    from {{ ref('blended_performance') }}
    where date_granularity = 'day'
      and channel in ('Meta', 'Google', 'TikTok')
      and date >= (select min(date) from shopify_daily)
    group by 1, 2, 3, 4

),

freshness as (

    -- Last day each platform has synced, capped at yesterday, taken over EVERY
    -- campaign on the platform so a paused campaign cannot make it look stale.
    select
        platform,
        least(max(date), (select today_local from today) - 1) as actuals_through
    from spend_rows
    group by 1

),

typed_spend as (

    -- Only budget lines that have a spend_type. Days past the freshness limit of
    -- their platform are dropped here, so they come out NULL below rather than 0.
    -- No apostrophes in comments in this file: the standalone compiler reads one as
    -- the start of a string and skips renaming CTE references until the next one.
    -- The mapping is
    -- INLINED, not a shared CTE, for the Redshift planner reason noted in
    -- blended_performance.sql.
    select
        s.date,
        s.platform,
        m.spend_type,
        sum(s.spend)        as spend
    from spend_rows s
    join ( {{ jm_budget_campaigns() }} ) m
        on  m.platform    = s.platform
        and m.campaign_id = s.campaign_id
        and (m.segment_match = '' or m.segment_match = s.segment)
    join freshness f
        on  f.platform = s.platform
    where m.spend_type <> ''
      and s.date <= f.actuals_through
    group by 1, 2, 3

),

spend_by_day as (

    select
        date,
        sum(case when platform = 'meta'   then spend end)      as spend_meta,
        sum(case when platform = 'google' then spend end)      as spend_google,
        sum(case when platform = 'tiktok' then spend end)      as spend_tiktok,
        sum(case when spend_type = 'prospecting' then spend end) as spend_prospecting,
        sum(case when spend_type = 'mixed'       then spend end) as spend_mixed,
        sum(case when spend_type = 'brand'       then spend end) as spend_brand,
        sum(case when spend_type = 'nonbrand'    then spend end) as spend_nonbrand
    from typed_spend
    group by 1

)

select
    h.date,
    date_trunc('month', h.date)::date   as month_start,
    h.new_customer_gross_sales,
    h.returning_customer_gross_sales,
    h.gross_sales,
    h.new_customers,
    p.spend_meta,
    p.spend_google,
    p.spend_tiktok,
    p.spend_prospecting,
    p.spend_mixed,
    p.spend_brand,
    p.spend_nonbrand
from shopify_daily h
left join spend_by_day p
    on  p.date = h.date
