/*
════════════════════════════════════════════════════════════════════════════════
  JM – Performance by Business & Channel (Monthly)  → Gsheet tab: data_month
════════════════════════════════════════════════════════════════════════════════
  Monthly trend, 18 months, both businesses in one card so Sephora and DTC sit
  side by side against the $57.2M / $17.2M split.

  WHAT IS TRUSTWORTHY HOW FAR BACK
    spend / delivery      Meta from 2023-07, Google from 2024-08
    cs_* (Sephora)        from 2025-03  — 18 months, the deepest history here
    shopify_* (DTC)       August 2026 ONLY is complete; July is a part-month
                          backfill (1,942 orders vs August's 14,962)

  So: Sephora MoM and YoY are both possible today. DTC blended MoM is not —
  blended_data_valid is FALSE for every month before 2026-08 and the sheet greys
  those cells. Paid-only DTC MoM/YoY is fine.
*/

with f as (

    select *
    from reporting.josiemaran_blended_performance
    where date_granularity = 'month'
      and date >= date_trunc('month', current_date) - interval '18 month'
      and date <  date_trunc('month', current_date)

),

agg as (

    select
        date                                    as period_start,
        grouping(business_line)                 as g_business,
        grouping(channel)                       as g_channel,
        business_line,
        channel,
        sum(spend)                              as spend,
        sum(impressions)                        as impressions,
        sum(clicks)                             as clicks,
        sum(paid_purchases)                     as paid_purchases,
        sum(paid_revenue)                       as paid_revenue,
        sum(cs_purchases)                       as cs_purchases,
        sum(cs_revenue)                         as cs_revenue,
        sum(shopify_orders)                     as site_orders,
        sum(shopify_new_customers)              as site_new_customers,
        sum(shopify_gross_sales)                as site_gross_sales
    from f
    group by grouping sets (
        (date),                                 -- All paid
        (date, business_line),                  -- Sephora / DTC
        (date, business_line, channel)          -- Sephora–Meta, DTC–Meta, DTC–Google, DTC–Shopify
    )

),

labelled as (

    select
        period_start,
        case
            when g_business = 1                 then 'Total Paid'
            when g_channel  = 1                 then business_line
            else business_line || ' – ' || channel
        end                                     as row_label,
        g_business, g_channel,
        spend, impressions, clicks,
        paid_purchases, paid_revenue,
        cs_purchases, cs_revenue,
        site_orders, site_new_customers, site_gross_sales
    from agg

)

select
    row_label,
    to_char(period_start, 'YYYY-MM')                            as period_label,
    period_start,
    row_label || ' | ' || to_char(period_start, 'YYYY-MM')       as lookup_key,

    round(spend, 2)                                             as spend,
    impressions,
    clicks,
    case when impressions > 0 then round(spend / impressions * 1000, 2) end    as cpm,
    case when clicks      > 0 then round(spend / clicks, 2) end                as cpc,

    round(paid_purchases, 0)                                    as paid_purchases,
    round(paid_revenue, 2)                                      as paid_revenue,
    case when spend > 0 then round(paid_revenue / spend, 2) end as paid_roas,

    -- Sephora side
    round(cs_purchases, 0)                                      as cs_purchases,
    round(cs_revenue, 2)                                        as cs_revenue,
    case when spend        > 0 then round(cs_revenue / spend, 2) end   as cs_roas,
    case when cs_purchases > 0 then round(spend / cs_purchases, 2) end as cs_cpa,

    -- DTC side
    site_orders,
    site_new_customers,
    round(site_gross_sales, 2)                                  as site_gross_sales,
    case when site_orders > 0 then round(site_gross_sales / site_orders, 2) end as aov,
    case when g_channel = 1 and spend > 0
         then round(site_gross_sales / spend, 2) end            as blended_roas,
    case when g_channel = 1 and site_new_customers > 0
         then round(spend / site_new_customers, 2) end          as blended_cac,

    -- Sephora cs_* is valid from 2025-03; DTC shopify_* only from 2026-08
    period_start >= '2025-03-01'                                as sephora_data_valid,
    period_start >= '2026-08-01'                                as blended_data_valid

from labelled
where coalesce(spend, 0) > 0 or coalesce(site_orders, 0) > 0
order by period_start desc, g_business desc, g_channel desc, row_label
