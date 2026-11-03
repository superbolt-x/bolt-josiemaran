-- kohls_sales_weekly: sales must be stores plus .com, a week with has_com = 0 must have no
-- .com, and every .com workbook week must land on a delivered store week (a .com week the
-- stores never reached would be silently dropped). Returns the offenders.
select week_start_date, sales, sales_bm, sales_com, has_com
from {{ ref('kohls_sales_weekly') }}
where abs(sales - (sales_bm + coalesce(sales_com, 0))) > 0.01
   or (has_com = 0 and sales_com is not null)

union all

select c.week_start_date, c.sales_com, null, c.sales_com, null
from (select week_start_date, sum(sales_com) as sales_com
      from {{ source('s3_retail_raw', 'kohls_com_weekly_workbook') }} group by 1) c
left join {{ ref('kohls_sales_weekly') }} w on w.week_start_date = c.week_start_date
where w.week_start_date is null
