{{ config (
    alias = target.database + '_shopify_sales_by_segment'
)}}

/*
    Site-side sales, re-aggregated from order grain so it carries the SAME
    dimensions as the paid side.

    Why this exists rather than just using `shopify_sales`:

      `<db>_shopify_sales` is already a tidy daily/weekly/monthly rollup, but it
      has no market and no order_type. That is precisely the flaw that broke the
      Sarah Creal build — its blended rows "aggregate order data, which has no
      campaign_name", so the Blended rollups could not be filtered to a market
      and silently mixed UK spend into US ROAS for a week before anyone noticed.

      Rebuilding from `shopify_daily_sales_by_order` gives us:
        market      <- shipping_address_country_code
        order_type  <- source_name  (subscriptions are 21% of orders here)
        is_first    <- customer_order_index = 1

    order_type matters more than it looks. 4,226 of 19,636 orders in the current
    window ($232k) arrive via `subscription_contract_checkout_one` — recurring
    revenue from customers acquired long before the reporting period. Leaving it
    in blended ROAS credits paid media for revenue it did not create this month.

    HISTORY FLOOR: Shopify order history begins 2026-03-25 (see
    var('shopify_history_floor')). Refunds, however, sync from 2016, so the
    unfloored table shows years of orders=0 with large negative net_sales
    (-$270k in 2025 alone). The floor keeps that out of the reporting layer.
*/

with orders as (

    select
        date,
        {{ jm_market_from_country('shipping_address_country_code') }} as market,

        case
            when source_name ilike 'subscription%' then 'Subscription'
            when source_name = 'web'               then 'Web'
            when source_name is null                then 'Unknown'
            else 'Other'
        end as order_type,

        order_id,
        customer_id,
        case when customer_order_index = 1 then 1 else 0 end as is_first_order,

        coalesce(gross_revenue, 0)    as gross_revenue,
        coalesce(subtotal_revenue, 0) as subtotal_revenue,
        coalesce(total_revenue, 0)    as total_revenue,
        coalesce(subtotal_discount, 0) as subtotal_discount,
        coalesce(total_tax, 0)        as total_tax,
        coalesce(shipping_price, 0)   as shipping_price

    from {{ ref('shopify_daily_sales_by_order') }}
    where date >= '{{ var("shopify_history_floor") }}'
      and cancelled_at is null

),

grains as (
    select 'day'     as date_granularity
    union all select 'week'
    union all select 'month'
    union all select 'quarter'
    union all select 'year'
),

spine as (

    {# Columns are listed explicitly: `o.*` would emit a second column also
       called `date` alongside the truncated one below and make the outer
       reference ambiguous. `order_date` is kept so min()/max() below report the
       real first/last order in the period rather than the period start. #}
    select
        g.date_granularity,
        case g.date_granularity
            when 'day'     then o.date
            when 'week'    then date_trunc('week',    o.date)::date
            when 'month'   then date_trunc('month',   o.date)::date
            when 'quarter' then date_trunc('quarter', o.date)::date
            when 'year'    then date_trunc('year',    o.date)::date
        end                        as date,
        o.date                     as order_date,
        o.market,
        o.order_type,
        o.order_id,
        o.customer_id,
        o.is_first_order,
        o.gross_revenue,
        o.subtotal_revenue,
        o.total_revenue,
        o.subtotal_discount,
        o.total_tax,
        o.shipping_price
    from orders o
    cross join grains g

)

select
    date,
    date_granularity,
    market,
    order_type,

    count(distinct order_id)                                               as orders,
    count(distinct case when is_first_order = 1 then order_id end)         as first_orders,
    count(distinct case when is_first_order = 0 then order_id end)         as repeat_orders,
    count(distinct customer_id)                                            as customers,
    count(distinct case when is_first_order = 1 then customer_id end)      as new_customers,

    sum(gross_revenue)                                                     as gross_sales,
    sum(subtotal_revenue)                                                  as subtotal_sales,
    sum(total_revenue)                                                     as total_sales,
    sum(subtotal_discount)                                                 as discounts,
    sum(total_tax)                                                         as tax,
    sum(shipping_price)                                                    as shipping,

    sum(case when is_first_order = 1 then gross_revenue else 0 end)        as first_order_gross_sales,
    sum(case when is_first_order = 0 then gross_revenue else 0 end)        as repeat_order_gross_sales,

    min(order_date)                                                        as min_order_date,
    max(order_date)                                                        as max_order_date,
    count(distinct order_date)                                             as days_with_orders

from spine
group by 1, 2, 3, 4
