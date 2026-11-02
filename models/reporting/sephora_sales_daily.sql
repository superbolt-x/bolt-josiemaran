{{ config (
    alias = target.database + '_sephora_sales_daily'
)}}

/*
════════════════════════════════════════════════════════════════════════════════
  josiemaran_sephora_sales_daily
════════════════════════════════════════════════════════════════════════════════

  GRAIN  one row per  date × business_unit        (sephora_us, sephora_ca)

  Sephora-reported sales and units rolled up from josiemaran_sephora_product_sales,
  split B&M (stores) and .com. This is the join-ready grain for the blended
  models: business_unit and date are the same keys as budget_pacing and the
  Sephora segments in blended_performance.

  Same rules as the product table: sales and units are NET of returns, NULL in
  the file counts as 0 (is_reported marks the real ones), and these are the
  retailer's numbers, never to be added to paid_* / cs_* / site_* figures.

    skus_listed    distinct SKUs on the grid that day (reported or not)
    skus_reported  distinct SKUs with a non-NULL sales value that day, B&M or .com
    rows_reported  rows the retailer actually filled in; 0 for a day it filled
                   nothing, which is "no record", not necessarily "sold nothing"

  Nothing here is forecast or estimated. A date with no row means the retailer has
  not delivered that week yet (or it is one of the weeks it says it is missing).
════════════════════════════════════════════════════════════════════════════════
*/

select
    date,
    week_start_date,
    business_unit,

    sum(sales)                                                          as sales,
    sum(case when location_type = 'B&M' then sales else 0 end)          as sales_bm,
    sum(case when location_type = '.com' then sales else 0 end)         as sales_com,
    sum(units)                                                          as units,
    sum(case when location_type = 'B&M' then units else 0 end)          as units_bm,
    sum(case when location_type = '.com' then units else 0 end)         as units_com,

    count(distinct channel_sku)                                         as skus_listed,
    count(distinct case when is_reported = 1 then channel_sku end)      as skus_reported,
    sum(is_reported)                                                    as rows_reported
from {{ ref('sephora_product_sales') }}
group by 1, 2, 3
