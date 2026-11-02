-- The retailer's weeks (4-5-4 calendar) must run Sunday to Saturday, seven days,
-- and every row's date must sit inside its own week. If the retailer ever changes
-- its calendar or a file is mislabelled, week_start_date stops lining up with the
-- warehouse's weeks (var week_start = Sunday) and week-over-week comparisons with
-- spend would be silently offset. Returns the offending weeks; the test passes
-- when it returns none.

select
    business_unit,
    week_start_date,
    week_end_date,
    min(date) as first_date,
    max(date) as last_date
from {{ ref('sephora_product_sales') }}
group by 1, 2, 3
having extract(dow from week_start_date) <> 0
    or week_end_date <> dateadd(day, 6, week_start_date)
    or min(date) < week_start_date
    or max(date) > week_end_date
