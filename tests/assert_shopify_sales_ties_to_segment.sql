/*
    Holds the two Shopify rollups together.

    shopify_sales (the packaged rollup, dbt var canceled_orders: 'included') and
    shopify_sales_by_segment (the order-grain rollup behind blended_performance, the
    weekly deck's site columns and the Gross Sales vs Spend charts) must agree, day by
    day, on gross sales, orders, first and repeat ORDER COUNTS, and new customers. Both
    count cancelled orders; a cancelled order has no customer_order_index, so it sits in
    gross sales and orders but in neither first nor repeat.

    NOT compared: first_order_gross_sales and repeat_order_gross_sales. They are not stable
    across builds of the order table. The package computes customer_order_index as
    ROW_NUMBER() OVER (PARTITION BY customer_id ... ORDER BY order_date) where order_date is
    processed_at::date, so a customer's orders on the SAME day tie and which one is "first"
    is arbitrary and can flip on every rebuild. The counts of first and repeat orders do not
    change (one of each), only their amounts, so two tables built from two builds disagree on
    the split by a few dollars a day (2026-10-12: 34 days, $1,511 in all, worst day $242, 0.08%
    of first-order gross sales) while gross sales, orders and new customers agree exactly.
    A test on the split would fail every cycle in which both Fivetran jobs rebuild the order
    table. The tie-break needs fixing in the package (ORDER BY order_date, order_id).

    They disagreed by exactly the cancelled orders' gross (0.4-1.1% a month, March to
    October 2026) when by_segment dropped cancelled orders. The team's reported revenue
    counts them (the 9/30 doc's $859.1K for Sep 1-28 is $859,952 with them, $853,986
    without), so by_segment now includes them.

    Inside by_segment the partition must also be complete (this is within ONE table, so it is stable):
        gross_sales = first_order_gross_sales + repeat_order_gross_sales + cancelled_order_gross_sales
    which fails if a non-cancelled order ever arrives without an order index.

    Window: from the Shopify history floor to three days ago, so an order that is
    synced or cancelled between two builds cannot fail it. 1 cent of tolerance covers
    float rounding only. Returns the days that disagree; none = pass.
*/

with a as (
    select
        date,
        coalesce(gross_sales, 0)              as gross_sales,
        coalesce(orders, 0)                   as orders,
        coalesce(first_orders, 0)             as first_orders,
        coalesce(repeat_orders, 0)            as repeat_orders,
        coalesce(new_customers, 0)            as new_customers
    from {{ ref('shopify_sales') }}
    where date_granularity = 'day'
      and date >= '{{ var("shopify_history_floor") }}'
      and date <= convert_timezone('{{ var("time_zone", "US/Eastern") }}', getdate())::date - 3
),

b as (
    select
        date,
        sum(gross_sales)                 as gross_sales,
        sum(first_order_gross_sales)     as first_gross,
        sum(repeat_order_gross_sales)    as repeat_gross,
        sum(cancelled_order_gross_sales) as cancelled_gross,
        sum(orders)                      as orders,
        sum(first_orders)                as first_orders,
        sum(repeat_orders)               as repeat_orders,
        sum(new_customers)               as new_customers
    from {{ ref('shopify_sales_by_segment') }}
    where date_granularity = 'day'
      and date <= convert_timezone('{{ var("time_zone", "US/Eastern") }}', getdate())::date - 3
    group by date
)

select
    coalesce(a.date, b.date)  as date,
    a.gross_sales             as shopify_sales_gross,
    b.gross_sales             as by_segment_gross,
    b.cancelled_gross         as by_segment_cancelled_gross,
    a.orders                  as shopify_sales_orders,
    b.orders                  as by_segment_orders
from a
full join b on a.date = b.date
where abs(coalesce(a.gross_sales, 0)  - coalesce(b.gross_sales, 0))  > 0.01
   or coalesce(a.orders, 0)        <> coalesce(b.orders, 0)
   or coalesce(a.first_orders, 0)  <> coalesce(b.first_orders, 0)
   or coalesce(a.repeat_orders, 0) <> coalesce(b.repeat_orders, 0)
   or coalesce(a.new_customers, 0) <> coalesce(b.new_customers, 0)
   or abs(coalesce(b.gross_sales, 0)
          - coalesce(b.first_gross, 0) - coalesce(b.repeat_gross, 0) - coalesce(b.cancelled_gross, 0)) > 0.01
