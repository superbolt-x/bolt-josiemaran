-- Kohl's weeks must run Sunday to Saturday, seven days, like the warehouse's weeks
-- (var week_start = Sunday). If the retailer changes its calendar or a file is
-- mislabelled, week-over-week comparisons with spend would be silently offset.
-- Returns the offending weeks; the test passes when it returns none.

select week_start_date, week_end_date
from {{ ref('kohls_product_sales') }}
group by 1, 2
having extract(dow from week_start_date) <> 0
    or week_end_date <> dateadd(day, 6, week_start_date)
