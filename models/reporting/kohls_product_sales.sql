{{ config (
    alias = target.database + '_kohls_product_sales'
)}}

/*
════════════════════════════════════════════════════════════════════════════════
  josiemaran_kohls_product_sales
════════════════════════════════════════════════════════════════════════════════

  GRAIN  one row per  week_start_date × channel_sku         (US, national)

  What KOHL'S says it sold of Josie Maran, by week and SKU, summed over its stores.
  business_unit is sephora_kohls, the key the budget sheet uses for Sephora @
  Kohl's (the Sephora shop inside Kohl's). The retailer's numbers: a separate
  family from paid_* (platform pixel), cs_* (catalog-segment actions) and site_*
  (Shopify). Never add them together; the point is to sit BESIDE spend.

  Source: s3_raw.kohls_product_store_weekly, loaded from the retailer's weekly files
  by retailer_s3_to_redshift.py. Weeks run Sunday to Saturday, the same as var
  week_start, so week_start_date lines up with the warehouse's weeks. History from
  2025-08-31. This feed is WEEKLY only: there is no daily Kohl's figure.

  ── Rows exist only where something happened ────────────────────────────────
  The feed has a row per week × store × SKU only when the store sold or returned
  the SKU (no NULLs, unlike the Sephora feed), and the number of stores grows from
  537 in the first week to ~1,150 now as the rollout widened. A week × SKU with no
  row means nothing sold, so it reads as 0, not as missing data. Whether a WEEK
  arrived at all is in s3_raw.coverage_feeds_weekly (feed kohls_weekly_sku_store,
  61 of 61 weeks complete on 2026-11-03), so a week the retailer never sent is not
  mistaken for a week with no sales.

  ── Returns are negative ────────────────────────────────────────────────────
  Sales and units are net of returns and can be below zero for a week.

  ── Two quirks passed through, not fixed ────────────────────────────────────
  Some rows carry units with 0 sales, almost all on UPC 840049909762 (Whipped Argan
  Oil Body Butter, Vanilla Vibezzz, 7.5 mL: 17,290 units, $0), which looks like a
  free or sample item; a few rows carry sales with 0 units. The retailer was asked.
  Sales and units here are sums of what was sent. units_with_sales counts units on
  rows that also have sales, for any per-unit price.

  ── Shopify mapping ─────────────────────────────────────────────────────────
  shopify_* columns come from sephora_shopify_sku_map (UPC = Shopify barcode).
  shopify_match: upc | override | retailer_only | none (see that model).
════════════════════════════════════════════════════════════════════════════════
*/

with src as (

    select * from {{ source('s3_retail_raw', 'kohls_product_store_weekly') }}

)

select
    week_start_date,
    week_end_date,
    'sephora_kohls'                                                     as business_unit,
    channel_sku,
    src.upc,

    max(jm_sku)                                                         as jm_sku,
    max(brand)                                                          as brand,
    max(product_name)                                                   as product_name,
    max(category)                                                       as category,
    max(beauty_category)                                                as beauty_category,
    max(franchise)                                                      as franchise,
    max(size_group)                                                     as size_group,
    max(fragrance)                                                      as fragrance,

    sum(coalesce(sales_usd, 0))                                         as sales,
    sum(coalesce(units, 0))                                             as units,
    sum(case when sales_usd <> 0 then units else 0 end)                 as units_with_sales,
    count(distinct case when units > 0 then store_no end)               as stores_selling,
    count(distinct store_no)                                            as stores_with_rows,

    max(m.shopify_variant_id)                                           as shopify_variant_id,
    max(m.shopify_product_id)                                           as shopify_product_id,
    max(m.shopify_sku)                                                  as shopify_sku,
    max(m.shopify_product_title)                                        as shopify_product_title,
    max(m.shopify_variant_name)                                         as shopify_variant_name,
    max(m.match_method)                                                 as shopify_match,

    max(delivered_at_utc)                                               as delivered_at_utc
from src
left join {{ ref('sephora_shopify_sku_map') }} m
    on m.upc = src.upc
group by 1, 2, 3, 4, 5
