{{ config (
    alias = target.database + '_kohls_sales_by_state_weekly'
)}}

/*
════════════════════════════════════════════════════════════════════════════════
  josiemaran_kohls_sales_by_state_weekly
════════════════════════════════════════════════════════════════════════════════

  GRAIN  one row per  week_start_date × state_province

  Kohl's-reported sales and units per week and US state, for geo comparisons with
  spend and Shopify by state. Net of returns, same rules as
  josiemaran_kohls_product_sales. Weekly only.

  Kohl's regions and districts are NOT a hierarchy of states (one state sits in up
  to four regions), so the table stops at state. Two stores arrive with no state
  (BALBOA, SAULT STE MARIE); they land under 'Unknown'.
════════════════════════════════════════════════════════════════════════════════
*/

select
    week_start_date,
    week_end_date,
    'sephora_kohls'                                                     as business_unit,
    coalesce(nullif(trim(state_province), ''), 'Unknown')               as state_province,

    sum(coalesce(sales_usd, 0))                                         as sales,
    sum(coalesce(units, 0))                                             as units,
    count(distinct case when units > 0 then store_no end)               as stores_selling,
    count(distinct case when units > 0 then channel_sku end)            as skus_sold
from {{ source('s3_retail_raw', 'kohls_product_store_weekly') }}
group by 1, 2, 3, 4
