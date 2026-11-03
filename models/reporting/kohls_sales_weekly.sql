{{ config (
    alias = target.database + '_kohls_sales_weekly'
)}}

/*
════════════════════════════════════════════════════════════════════════════════
  josiemaran_kohls_sales_weekly
════════════════════════════════════════════════════════════════════════════════

  GRAIN  one row per  week_start_date × business_unit        (sephora_kohls)

  Kohl's-reported sales and units per week, rolled up from
  josiemaran_kohls_product_sales. The join-ready grain for the blended models: the
  same week_start_date (Sunday) and business_unit keys as the weekly spend and
  budget tables. Weekly only; the retailer sends no daily Kohl's figure.

  Same rules as the product table: sales and units are NET of returns, a missing
  week × SKU means nothing sold, and these are the retailer's numbers, never to be
  added to paid_* / cs_* / site_* figures.

    skus_sold      distinct SKUs with positive units that week
    stores_selling distinct stores that sold anything that week (from the store
                   grain, so it is not the sum of the product rows)

  ── Stores and .com ─────────────────────────────────────────────────────────
  The retailer's Kohl's files are STORES ONLY (sales_bm, units_bm). Kohl's.com
  comes from the client's workbook (s3_raw.kohls_com_weekly_workbook, loaded by hand,
  a stop-gap until the retailer sends it): sales_com, units_com. sales and units are
  the two added. has_com = 1 when the workbook covers that week; a week after its last
  one has stores only and has_com = 0, so its total is short by .com. Read has_com.
  The product and state models stay stores only.
════════════════════════════════════════════════════════════════════════════════
*/

select
    p.week_start_date,
    p.week_end_date,
    p.business_unit,

    sum(p.sales) + coalesce(max(c.sales_com), 0)                        as sales,
    sum(p.units) + coalesce(max(c.units_com), 0)                        as units,
    sum(p.sales)                                                        as sales_bm,
    max(c.sales_com)                                                    as sales_com,
    sum(p.units)                                                        as units_bm,
    max(c.units_com)                                                    as units_com,
    case when max(c.week_start_date) is not null then 1 else 0 end      as has_com,
    count(distinct case when p.units > 0 then p.channel_sku end)        as skus_sold,
    max(s.stores_selling)                                               as stores_selling
from {{ ref('kohls_product_sales') }} p
left join (
    select week_start_date, count(distinct case when units > 0 then store_no end) as stores_selling
    from {{ source('s3_retail_raw', 'kohls_product_store_weekly') }}
    group by 1
) s
    on s.week_start_date = p.week_start_date
left join (
    select week_start_date, sum(sales_com) as sales_com, sum(units_com) as units_com
    from {{ source('s3_retail_raw', 'kohls_com_weekly_workbook') }}
    group by 1
) c
    on c.week_start_date = p.week_start_date
group by 1, 2, 3
