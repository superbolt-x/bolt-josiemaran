{{ config (
    alias = target.database + '_kohls_sales_weekly'
)}}

/*
════════════════════════════════════════════════════════════════════════════════
  josiemaran_kohls_sales_weekly
════════════════════════════════════════════════════════════════════════════════

  GRAIN  one row per  week_start_date × business_unit        (sephora_kohls)

  Kohl's-reported sales and units per week, stores and .com. The join-ready grain
  for the blended models: the same week_start_date (Sunday) and business_unit keys
  as the weekly spend and budget tables. Weekly only; the retailer sends no daily
  Kohl's figure.

  Sales and units are NET of returns, and these are the retailer's numbers, never to
  be added to paid_* / cs_* / site_* figures.

    sales_bm / units_bm    stores
    sales_com / units_com  Kohl's.com
    sales / units          the two added
    has_com                1 when the week carries .com rows (every delivered week
                           since 2026-11-05: the feed has both locations)
    skus_sold              distinct SKUs with positive units that week, either channel
    stores_selling         distinct stores that sold anything that week, from the
                           store feed (stores only, so not the sum of the product rows)

  ── Source ──────────────────────────────────────────────────────────────────
  s3_raw.kohls_product_weekly (kohls_us_product_weekly files, SKU x location_type
  B&M / .com, no store detail), delivered by the retailer from 2026-11-05. It
  replaced the hand-loaded workbook stop-gap for .com and the store-level feed for
  the stores total: the retailer's product feed is the figure it stands behind
  (it reproduces the client's workbook to the cent, .com in 61 of 61 weeks and
  stores in all but the five weeks where the older store feed ran high, by $4,725
  net, $4,812 of it in week 2026-10-18). The store feed (kohls_product_sales,
  kohls_sales_by_state_weekly) still gives product and state detail and can differ
  from this by those weeks; assert_kohls_store_feed_ties_to_product_feed warns
  about it.
════════════════════════════════════════════════════════════════════════════════
*/

select
    p.week_start_date,
    p.week_end_date,
    'sephora_kohls'                                                     as business_unit,

    sum(coalesce(p.sales_usd, 0))                                       as sales,
    sum(coalesce(p.units, 0))                                           as units,
    sum(case when p.location_type = 'B&M' then coalesce(p.sales_usd, 0) else 0 end)    as sales_bm,
    sum(case when p.location_type = '.com' then coalesce(p.sales_usd, 0) end)           as sales_com,
    sum(case when p.location_type = 'B&M' then coalesce(p.units, 0) else 0 end)         as units_bm,
    sum(case when p.location_type = '.com' then coalesce(p.units, 0) end)               as units_com,
    max(case when p.location_type = '.com' then 1 else 0 end)           as has_com,
    count(distinct case when p.units > 0 then p.channel_sku end)        as skus_sold,
    max(s.stores_selling)                                               as stores_selling
from {{ source('s3_retail_raw', 'kohls_product_weekly') }} p
left join (
    select week_start_date, count(distinct case when units > 0 then store_no end) as stores_selling
    from {{ source('s3_retail_raw', 'kohls_product_store_weekly') }}
    group by 1
) s
    on s.week_start_date = p.week_start_date
group by 1, 2, 3
