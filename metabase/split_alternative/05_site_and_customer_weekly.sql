/*
════════════════════════════════════════════════════════════════════════════════
  JM – Site & Customer Summary (Weekly)          → Gsheet tab: data_site_wk
════════════════════════════════════════════════════════════════════════════════
  JM.com on its own, split by order_type — the split that decides whether a
  blended number means anything here.

  4,226 of 19,636 orders ($232,177) arrive via `subscription_contract_checkout_one`
  and 78% of all orders are repeat purchases (mean customer_order_index = 10).
  This is a brand with a large established base, so site revenue moves largely
  independently of this week's spend.

  Against the plan's 70 New / 20 Engaged / 10 Existing target — versus 66%
  currently going to reactivation — `new_customer_cac` and `pct_new_orders` are
  the numbers to manage. Blended ROAS is a guardrail.
*/

with f as (

    select *
    from reporting.josiemaran_blended_performance
    where date_granularity = 'week'
      and channel = 'Shopify'
      and date >= date_trunc('week', current_date) - interval '13 week'
      and date <  date_trunc('week', current_date)

),

dtc_spend as (

    -- DTC spend only. Sephora spend drives sephora.com and must never sit in
    -- the denominator of a JM.com efficiency metric.
    select date, sum(spend) as dtc_spend
    from reporting.josiemaran_blended_performance
    where date_granularity = 'week'
      and business_line = 'DTC'
      and channel <> 'Shopify'
      and date >= date_trunc('week', current_date) - interval '13 week'
      and date <  date_trunc('week', current_date)
    group by 1

),

agg as (

    select
        date                                    as period_start,
        market,
        order_type,
        sum(shopify_orders)                     as orders,
        sum(shopify_first_orders)               as first_orders,
        sum(shopify_repeat_orders)              as repeat_orders,
        sum(shopify_new_customers)              as new_customers,
        sum(shopify_gross_sales)                as gross_sales,
        sum(shopify_total_sales)                as total_sales,
        sum(shopify_discounts)                  as discounts
    from f
    group by grouping sets (
        (date),                                 -- all markets, all order types
        (date, order_type),                     -- Web vs Subscription
        (date, market)                          -- US / CA
    )

)

select
    coalesce(a.order_type, 'All')                               as order_type,
    coalesce(a.market, 'All')                                    as market,
    to_char(a.period_start, 'IYYY-"W"IW')                        as period_label,
    a.period_start,
    coalesce(a.order_type, 'All') || ' | ' || coalesce(a.market, 'All')
        || ' | ' || to_char(a.period_start, 'IYYY-"W"IW')        as lookup_key,

    a.orders,
    a.first_orders,
    a.repeat_orders,
    a.new_customers,
    round(a.gross_sales, 2)                                     as gross_sales,
    round(a.total_sales, 2)                                     as total_sales,
    round(a.discounts, 2)                                       as discounts,

    case when a.orders > 0 then round(a.gross_sales / a.orders, 2) end            as aov,
    case when a.orders > 0 then round(a.first_orders::numeric / a.orders, 4) end  as pct_new_orders,
    case when a.gross_sales > 0 then round(a.discounts / a.gross_sales, 4) end    as discount_rate,

    -- Efficiency vs DTC spend, only on the all/all row
    case when a.order_type is null and a.market is null
         then round(s.dtc_spend, 2) end                                           as dtc_spend,
    case when a.order_type is null and a.market is null and a.new_customers > 0
         then round(s.dtc_spend / a.new_customers, 2) end                         as new_customer_cac,
    case when a.order_type is null and a.market is null and s.dtc_spend > 0
         then round(a.gross_sales / s.dtc_spend, 2) end                            as blended_roas_dtc,

    a.period_start >= '2026-07-27'                              as blended_data_valid

from agg a
left join dtc_spend s on s.date = a.period_start
order by a.period_start desc, order_type, market
