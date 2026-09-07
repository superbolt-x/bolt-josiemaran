/*
════════════════════════════════════════════════════════════════════════════════
  JM – DTC Performance by Channel (Weekly)        → Gsheet tab: data_dtc_wk
════════════════════════════════════════════════════════════════════════════════
  The JM.com business ($17.2M of the $75M 2026 plan). Blended rollups here are
  DTC spend over Shopify revenue — Sephora spend is a different business_line
  and cannot leak into the denominator.

  ⚠ Blended columns are only valid from the week of 2026-07-27. Shopify order
  history starts there: 19 orders in the week of 07-20, then 2,737 in the week
  of 07-27. Earlier weeks return real spend divided by orders that were never
  synced — a flattering ROAS, not an empty cell. Hence blended_data_valid.

  The DTC priority in the plan is a 70 New / 20 Engaged / 10 Existing split
  against 66% currently going to reactivation, so new-customer CAC is the
  metric to manage, not blended ROAS.
*/

with f as (

    select *
    from reporting.josiemaran_blended_performance
    where date_granularity = 'week'
      and business_line = 'DTC'
      and date >= date_trunc('week', current_date) - interval '13 week'
      and date <  date_trunc('week', current_date)

),

agg as (

    select
        date                                    as period_start,
        grouping(channel)                       as g_channel,
        grouping(meta_segment)                  as g_segment,
        channel,
        meta_segment,
        sum(spend)                              as spend,
        sum(impressions)                        as impressions,
        sum(clicks)                             as clicks,
        sum(paid_purchases)                     as paid_purchases,
        sum(paid_revenue)                       as paid_revenue,
        sum(shopify_orders)                     as site_orders,
        sum(shopify_first_orders)               as site_first_orders,
        sum(shopify_new_customers)              as site_new_customers,
        sum(shopify_gross_sales)                as site_gross_sales
    from f
    group by grouping sets (
        (date),                                 -- Blended DTC (spend + site)
        (date, channel),                        -- Meta / Google / Shopify
        (date, channel, meta_segment)           -- DTC ASC, DTC Retargeting, …
    )

),

labelled as (

    select
        period_start,
        case
            when g_channel = 1                  then 'Blended DTC'
            when g_segment = 1                  then channel
            else coalesce(meta_segment, channel)
        end                                     as row_label,
        g_channel,
        spend, impressions, clicks,
        paid_purchases, paid_revenue,
        site_orders, site_first_orders, site_new_customers, site_gross_sales
    from agg

)

select
    row_label,
    to_char(period_start, 'IYYY-"W"IW')                         as period_label,
    period_start,
    row_label || ' | ' || to_char(period_start, 'IYYY-"W"IW')   as lookup_key,

    round(spend, 2)                                             as spend,
    impressions,
    clicks,
    case when impressions > 0 then round(spend / impressions * 1000, 2) end    as cpm,
    case when impressions > 0 then round(clicks::numeric / impressions, 4) end as ctr,
    case when clicks      > 0 then round(spend / clicks, 2) end                as cpc,

    round(paid_purchases, 0)                                    as paid_purchases,
    round(paid_revenue, 2)                                      as paid_revenue,
    case when spend          > 0 then round(paid_revenue / spend, 2) end   as paid_roas,
    case when paid_purchases > 0 then round(spend / paid_purchases, 2) end as paid_cpa,

    site_orders,
    site_new_customers,
    round(site_gross_sales, 2)                                  as site_gross_sales,
    case when site_orders > 0 then round(site_gross_sales / site_orders, 2) end          as aov,
    case when site_orders > 0 then round(site_new_customers::numeric / site_orders, 4) end as pct_new,

    -- Blended only where channels are rolled up and both sides are present
    case when g_channel = 1 and spend > 0
         then round(site_gross_sales / spend, 2) end             as blended_roas,
    case when g_channel = 1 and site_new_customers > 0
         then round(spend / site_new_customers, 2) end           as blended_cac,

    period_start >= '2026-07-27'                                as blended_data_valid

from labelled
where coalesce(spend, 0) > 0 or coalesce(site_orders, 0) > 0
order by period_start desc, g_channel desc, row_label
