/*
════════════════════════════════════════════════════════════════════════════════
  JM – Reporting Feed                    → ONE Gsheet tab: `feed`
════════════════════════════════════════════════════════════════════════════════

  ONE card, ONE extension connection, every report level. The Gsheet does the
  rest with QUERY() / INDEX+MATCH.

  Long in the dimensions, wide in the metrics — the shape both sheet techniques
  want. QUERY() filters rows by `report_level`; INDEX+MATCH finds a row by
  `lookup_key` and a column by header name.

  ── Segments come from CAMPAIGN IDs ─────────────────────────────────────────
  Defined in seeds/campaign_segments.csv from the reporting deck, not parsed
  from campaign names. Seven segments:

      Google Overall · Meta Overall            ┐ together = Paid DTC Overall
      Sephora US Traffic · Sephora US Collab   │
      Sephora CA Traffic · Sephora CA Collab   │
      Sephora @ Kohls                          ┘

  Anything unmapped shows as segment 'Unmapped' and appears on the Health rows
  with its spend. It is never folded into a total.

  ── report_level ────────────────────────────────────────────────────────────
    Sephora Segment   weekly · the four Sephora segments + Kohl's, plus a
                      Sephora total. Read cs_*.
    DTC Segment       weekly · Paid DTC Overall, Meta Overall, Google Overall,
                      Shopify. Read paid_* / site_* / blended_*.
    Business          monthly · Total Paid, Sephora, DTC, 18 months. MoM/YoY.
    Campaign          weekly · campaign drilldown with IDs, 9 weeks.
    Site              weekly · JM.com by order_type and market.
    Health            no period · freshness / catalog-feedback / mapping /
                      zero-conversion checks. Carries `status` + `detail`
                      instead of metrics.

  ── The column to read first ────────────────────────────────────────────────
  `read_metrics` names the metric family that applies to each row, because the
  two businesses do not share a conversion source:

      cs_*        Sephora — converts on SEPHORA's pixel via catalog segment.
                  paid_purchases is ~0 for this whole business (18 purchases on
                  $566,802 of 2026 spend) and Shopify never sees the order.
      paid_*      DTC platform-attributed (Meta / Google own pixel).
      site_*      JM.com actuals from Shopify.
      blended_*   DTC spend ÷ Shopify revenue. Only on rollup rows.

  Putting a cs_* number next to a paid_* number and calling it "Meta" is the
  mistake this whole model exists to prevent. The column says which is which.

  ── data_valid ──────────────────────────────────────────────────────────────
  FALSE means the row's headline metric rests on data that is not there:
    · DTC/Site/blended before the week of 2026-07-27 — Shopify order history
      starts there (19 orders the week before, 2,737 that week), so earlier
      periods divide real spend by orders that never synced. A flattering
      ROAS, not an empty cell.
    · Sephora before 2025-03 — catalog segment history starts then.
  Grey these in the sheet. Do not filter them out; a visible gap is the point.

  ── has_catalog_feedback ────────────────────────────────────────────────────
  Sephora rows only. FALSE = real spend, unreported conversions. Currently the
  new `SB - US/CA - Sephora … Traffic` campaigns (~92% of live Sephora spend),
  Kohl's traffic, and the retired Engagement campaign. Amber in the sheet —
  this is spend to act on, not history to ignore.

  NO TEMPLATE TAGS anywhere: keeps the card publishable as a public CSV and
  usable by the extension without parameter plumbing. Market and period
  selection belong in the sheet.

  Weeks come from the warehouse's native Monday `date_granularity = 'week'`.
  Never re-derive weeks in SQL here.
*/

with

wk as (
    select *
    from reporting.josiemaran_blended_performance
    where date_granularity = 'week'
      and date >= date_trunc('week', current_date) - interval '13 week'
      and date <  date_trunc('week', current_date)      -- exclude in-progress week
),

mo as (
    select *
    from reporting.josiemaran_blended_performance
    where date_granularity = 'month'
      and date >= date_trunc('month', current_date) - interval '18 month'
      and date <  date_trunc('month', current_date)
),

-- ═══ LEVEL 1 · Sephora Segment (weekly) ═════════════════════════════════════
sephora_segment as (

    select
        'Sephora Segment'                       as report_level,
        case when grouping(segment) = 1 and grouping(market) = 0
                  then 'Sephora – ' || market
             when grouping(segment) = 1 then 'Sephora – Total'
             else segment end                   as row_label,
        coalesce(market, 'All')                  as market,
        'week'                                  as grain,
        date                                    as period_start,
        grouping(segment)                       as is_rollup,
        'cs_*'                                  as read_metrics,
        sum(spend)                              as spend,
        sum(impressions)                        as impressions,
        sum(clicks)                             as clicks,
        cast(null as double precision)          as paid_purchases,
        cast(null as double precision)          as paid_revenue,
        sum(cs_purchases)                       as cs_purchases,
        sum(cs_revenue)                         as cs_revenue,
        sum(cs_offline_purchases)               as cs_offline_purchases,
        sum(cs_add_to_cart)                     as cs_add_to_cart,
        cast(null as bigint)                    as site_orders,
        cast(null as bigint)                    as site_first_orders,
        cast(null as bigint)                    as site_new_customers,
        cast(null as double precision)          as site_gross_sales,
        cast(null as varchar(8))                as status,
        cast(null as varchar(256))              as detail
    from wk
    where business_line = 'Sephora'          -- Meta AND TikTok
    group by grouping sets ((date), (date, market), (date, segment))
    having sum(spend) > 0

),

-- ═══ LEVEL 2 · DTC Segment (weekly) ═════════════════════════════════════════
--  `Paid DTC Overall` is the rollup of the Meta Overall + Google Overall
--  campaign IDs — not "everything in the DTC account". Historical and
--  non-reported DTC campaigns are segment 'Unmapped' and excluded here, which
--  is why the rollup is filtered on in_dtc_overall rather than on channel.
dtc_segment as (

    select
        'DTC Segment'                           as report_level,
        case when grouping(segment) = 1 then 'Paid DTC Overall'
             else segment end                   as row_label,
        'All'                                   as market,
        'week'                                  as grain,
        date                                    as period_start,
        grouping(segment)                       as is_rollup,
        case when grouping(segment) = 1 then 'blended_*' else 'paid_*' end as read_metrics,
        sum(spend), sum(impressions), sum(clicks),
        sum(paid_purchases), sum(paid_revenue),
        cast(null as double precision), cast(null as double precision),
        cast(null as double precision), cast(null as double precision),
        sum(shopify_orders), sum(shopify_first_orders),
        sum(shopify_new_customers), sum(shopify_gross_sales),
        cast(null as varchar(8)), cast(null as varchar(256))
    from wk
    where business_line = 'DTC'
      and (in_dtc_overall or channel = 'Shopify')
    group by grouping sets ((date), (date, segment))
    having sum(spend) > 0 or sum(shopify_orders) > 0

),

-- ═══ LEVEL 3 · Business (monthly) ═══════════════════════════════════════════
business as (

    select
        'Business'                              as report_level,
        case when grouping(business_line) = 1 then 'Total Paid'
             when grouping(channel) = 1 then business_line
             else business_line || ' – ' || channel end as row_label,
        'All'                                   as market,
        'month'                                 as grain,
        date                                    as period_start,
        grouping(channel)                       as is_rollup,
        case when grouping(business_line) = 1                  then 'paid_*'
             when business_line = 'Sephora'                     then 'cs_*'
             when grouping(channel) = 1                         then 'blended_*'
             else 'paid_*' end                  as read_metrics,
        sum(spend), sum(impressions), sum(clicks),
        sum(paid_purchases), sum(paid_revenue),
        sum(cs_purchases), sum(cs_revenue),
        sum(cs_offline_purchases), sum(cs_add_to_cart),
        sum(shopify_orders), sum(shopify_first_orders),
        sum(shopify_new_customers), sum(shopify_gross_sales),
        cast(null as varchar(8)), cast(null as varchar(256))
    from mo
    group by grouping sets ((date), (date, business_line), (date, business_line, channel))
    having sum(spend) > 0 or sum(shopify_orders) > 0

),

-- ═══ LEVEL 4 · Campaign (weekly) ════════════════════════════════════════════
campaign as (

    select
        'Campaign'                              as report_level,
        campaign_id || '  ·  ' || coalesce(campaign_name, '(no name)') as row_label,
        market,
        'week'                                  as grain,
        date                                    as period_start,
        0                                       as is_rollup,
        case when business_line = 'Sephora' then 'cs_*' else 'paid_*' end as read_metrics,
        sum(spend), sum(impressions), sum(clicks),
        sum(paid_purchases), sum(paid_revenue),
        sum(cs_purchases), sum(cs_revenue),
        sum(cs_offline_purchases), sum(cs_add_to_cart),
        cast(null as bigint), cast(null as bigint),
        cast(null as bigint), cast(null as double precision),
        cast(null as varchar(8)), cast(null as varchar(256))
    from wk
    where channel <> 'Shopify'
      and date >= date_trunc('week', current_date) - interval '9 week'
      and campaign_id is not null
    group by campaign_id, campaign_name, market, date, business_line, segment
    having sum(spend) > 0

),

-- ═══ LEVEL 5 · Site (weekly) ════════════════════════════════════════════════
site as (

    select
        'Site'                                  as report_level,
        coalesce(order_type, 'All')              as row_label,
        coalesce(market, 'All')                  as market,
        'week'                                  as grain,
        date                                    as period_start,
        grouping(order_type)                    as is_rollup,
        'site_*'                                as read_metrics,
        cast(null as double precision), cast(null as bigint), cast(null as double precision),
        cast(null as double precision), cast(null as double precision),
        cast(null as double precision), cast(null as double precision),
        cast(null as double precision), cast(null as double precision),
        sum(shopify_orders), sum(shopify_first_orders),
        sum(shopify_new_customers), sum(shopify_gross_sales),
        cast(null as varchar(8)), cast(null as varchar(256))
    from wk
    where channel = 'Shopify'
    group by grouping sets ((date), (date, order_type), (date, market))
    having sum(shopify_orders) > 0

),

-- ═══ LEVEL 6 · Health (no period) ═══════════════════════════════════════════
health_freshness as (
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
    where date_granularity = 'day' and business_line = 'Sephora' and channel = 'Meta'
      and date >= dateadd(day, -30, current_date)
    group by 1
),

health_mapping as (
    -- Spend on campaign IDs not in seeds/campaign_segments.csv. Any live
    -- campaign landing here is invisible to every segment row, so this is the
    -- check that catches a launch nobody added to the mapping.
    --
    -- Window is 7 days, not 30, on purpose: the nine predecessors of the
    -- current structure all stopped spending by 2026-08-27, so a 30-day window
    -- reports $44,184 of correctly-unmapped retired spend and cries wolf
    -- through the whole transition. 7 days reflects the live account.
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
    where date_granularity = 'day'
      and channel <> 'Shopify'
      and date >= dateadd(day, -7, current_date)

    union all

    select
        'NULL campaign_id (7d)', 'mapping',
        '$' || round(sum(case when campaign_id is null then spend else 0 end))::varchar
            || ' of $' || round(sum(spend))::varchar,
        case when sum(case when campaign_id is null then spend else 0 end) > 0
             then 'FAIL' else 'OK' end
    from reporting.josiemaran_blended_performance
    where date_granularity = 'day'
      and channel <> 'Shopify'
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
    where date_granularity = 'day' and channel <> 'Shopify'
      and date >= dateadd(day, -30, current_date)
    group by 1
),

health as (
    select
        'Health'                    as report_level,
        check_name || ': ' || subject as row_label,
        'All'                       as market,
        'n/a'                       as grain,
        current_date                as period_start,
        0                           as is_rollup,
        'status'                    as read_metrics,
        cast(null as double precision), cast(null as bigint), cast(null as double precision),
        cast(null as double precision), cast(null as double precision),
        cast(null as double precision), cast(null as double precision),
        cast(null as double precision), cast(null as double precision),
        cast(null as bigint), cast(null as bigint),
        cast(null as bigint), cast(null as double precision),
        status, detail
    from (
        select * from health_freshness
        union all select * from health_catalog
        union all select * from health_mapping
        union all select * from health_zero
    ) h
),

unioned as (
    select * from sephora_segment
    union all select * from dtc_segment
    union all select * from business
    union all select * from campaign
    union all select * from site
    union all select * from health
)

-- ── Derived metrics computed ONCE, over the union ───────────────────────────
-- Every rate and ratio is defined in exactly one place here rather than
-- repeated per branch. That is the whole reason the branches emit raw sums.
select
    report_level,
    row_label,
    market,
    grain,
    case grain when 'week'  then to_char(period_start, 'IYYY-"W"IW')
               when 'month' then to_char(period_start, 'YYYY-MM')
               else '' end                                      as period_label,
    period_start,
    read_metrics,

    report_level || '|' || row_label || '|' || market || '|' ||
        case grain when 'week'  then to_char(period_start, 'IYYY-"W"IW')
                   when 'month' then to_char(period_start, 'YYYY-MM')
                   else '' end                                  as lookup_key,

    -- ── Delivery ───────────────────────────────────────────────────────────
    round(spend, 2)                                             as spend,
    impressions,
    round(clicks, 0)                                            as clicks,
    case when impressions > 0 then round(spend / impressions * 1000, 2) end     as cpm,
    case when impressions > 0 then round(clicks::numeric / impressions, 4) end  as ctr,
    case when clicks      > 0 then round(spend / clicks, 2) end                 as cpc,

    -- ── DTC platform-attributed ────────────────────────────────────────────
    round(paid_purchases, 0)                                    as paid_purchases,
    round(paid_revenue, 2)                                      as paid_revenue,
    case when spend          > 0 then round(paid_revenue / spend, 2) end   as paid_roas,
    case when paid_purchases > 0 then round(spend / paid_purchases, 2) end as paid_cpa,

    -- ── Sephora catalog segment ────────────────────────────────────────────
    round(cs_purchases, 0)                                      as cs_purchases,
    round(cs_revenue, 2)                                        as cs_revenue,
    case when spend        > 0 then round(cs_revenue / spend, 2) end        as cs_roas,
    case when cs_purchases > 0 then round(spend / cs_purchases, 2) end      as cs_cpa,
    case when cs_purchases > 0 then round(cs_revenue / cs_purchases, 2) end as cs_aov,
    round(cs_add_to_cart, 0)                                    as cs_add_to_cart,
    round(cs_offline_purchases, 0)                              as cs_instore_purchases,
    case when cs_purchases > 0
         then round(cs_offline_purchases::numeric / cs_purchases, 4) end    as pct_instore,

    -- ── JM.com actuals ─────────────────────────────────────────────────────
    site_orders,
    site_first_orders,
    site_new_customers,
    round(site_gross_sales, 2)                                  as site_gross_sales,
    case when site_orders > 0 then round(site_gross_sales / site_orders, 2) end            as aov,
    case when site_orders > 0 then round(site_first_orders::numeric / site_orders, 4) end  as pct_new,

    -- ── Blended: rollup rows only, so a channel row can never show one ─────
    case when is_rollup = 1 and spend > 0 and site_gross_sales > 0
         then round(site_gross_sales / spend, 2) end             as blended_roas,
    case when is_rollup = 1 and spend > 0 and site_new_customers > 0
         then round(spend / site_new_customers, 2) end           as blended_cac,

    -- ── Flags ──────────────────────────────────────────────────────────────
    case
        when report_level = 'Health'            then true
        when report_level = 'Sephora Segment'   then period_start >= '2025-03-01'
        when report_level = 'Business'
             and row_label like 'Sephora%'      then period_start >= '2025-03-01'
        when grain = 'month'                     then period_start >= '2026-08-01'
        else period_start >= '2026-07-27'
    end                                                         as data_valid,

    case when read_metrics = 'cs_*'
         then coalesce(cs_purchases, 0) > 0 or coalesce(cs_add_to_cart, 0) > 0
    end                                                         as has_catalog_feedback,

    status,
    detail

from unioned
order by
    case report_level when 'Health' then 0 when 'Business' then 1
         when 'Sephora Segment' then 2 when 'DTC Segment' then 3
         when 'Site' then 4 else 5 end,
    period_start desc,
    is_rollup desc,
    spend desc nulls last,
    row_label
