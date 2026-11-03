-- The 7 spread days of a Kohl's week must add back to the delivered week, and every
-- delivered week must have exactly 7 days. Returns the weeks that do not.
select
    w.week_start_date,
    w.sales as week_sales,
    sum(d.sales) as daily_sales,
    w.units as week_units,
    sum(d.units) as daily_units,
    count(d.date) as days
from {{ ref('kohls_sales_weekly') }} w
left join {{ ref('kohls_sales_daily_estimated') }} d
    on d.week_start_date = w.week_start_date
group by w.week_start_date, w.sales, w.units, w.sales_bm
having count(d.date) <> 7
    or abs(sum(d.sales) - w.sales) > 0.01
    or abs(sum(d.units) - w.units) > 0.001
    or abs(sum(d.sales_bm) - w.sales_bm) > 0.01
