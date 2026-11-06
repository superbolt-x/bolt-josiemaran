-- kohls_sales_weekly: sales must be stores plus .com, and a week with has_com = 0 must have
-- no .com. Returns the offenders.
select week_start_date, sales, sales_bm, sales_com, has_com
from {{ ref('kohls_sales_weekly') }}
where abs(sales - (sales_bm + coalesce(sales_com, 0))) > 0.01
   or (has_com = 0 and sales_com is not null)
