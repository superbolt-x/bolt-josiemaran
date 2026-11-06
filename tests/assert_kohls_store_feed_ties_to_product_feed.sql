{{ config(severity = 'warn') }}
-- The store-level feed (kohls_product_sales, the product and state models) should add up to the
-- stores total of kohls_sales_weekly (the retailer's product feed). They differ by a few dollars
-- in 4 weeks and by $4,812 in week 2026-10-18 (the store feed ran high; the retailer's product
-- feed is the figure it stands behind). Warns, so a NEW difference is noticed; returns the weeks.
select w.week_start_date, w.sales_bm as product_feed, s.sales as store_feed, s.sales - w.sales_bm as diff
from {{ ref('kohls_sales_weekly') }} w
left join (select week_start_date, sum(sales) as sales
           from {{ ref('kohls_product_sales') }} group by 1) s
    on s.week_start_date = w.week_start_date
where abs(coalesce(s.sales, 0) - w.sales_bm) > 1
