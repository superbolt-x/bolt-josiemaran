{{ config (
    alias = target.database + '_sephora_product_sales'
)}}

/*
════════════════════════════════════════════════════════════════════════════════
  josiemaran_sephora_product_sales
════════════════════════════════════════════════════════════════════════════════

  GRAIN  one row per  date × business_unit × location_type × channel_sku

  What SEPHORA says it sold, by day and SKU, country level (no state). The
  retailer's numbers: a separate family from paid_* (platform pixel), cs_*
  (catalog-segment actions) and site_* (Shopify). Never add them together;
  the point of this table is to sit BESIDE spend, not inside it.

  Source: s3_raw.sephora_product_daily, loaded from the retailer's weekly files by
  retailer_s3_to_redshift.py. Weeks run Sunday to Saturday (the retailer's 4-5-4
  calendar), the same as var week_start, so week_start_date lines up with the
  warehouse's weeks. Months do not line up with the retailer's periods.

  ── NULL is "no source record", and it is filled with 0 here ────────────────
  The retailer sends a SKU × day grid and leaves sales and units NULL where it has
  no record. The NULLs are scattered over SKU-days and identical for B&M and
  .com on the same day, so they read as "nothing recorded", not as a failed
  load. Sums are the same either way (SUM skips NULL). The raw table keeps NULL;
  `sales` and `units` here are 0 on those rows, and is_reported says which ones
  the retailer actually reported (0 = NULL in the file). An explicit 0.0 in the
  file is is_reported = 1. If the store feed (daily, by store) later disagrees
  with this feed at country level, revisit this rule first.

  ── Returns are negative ────────────────────────────────────────────────────
  A negative sales or units value is a return. It stays in, so SUM(sales) is net
  of returns.

  ── Business unit comes from the FILE NAME, not from retailer_country ───────
  _source_key starts <retailer>_<country>_, which gives sephora_us / sephora_ca,
  the warehouse's business_unit keys. retailer_country inside other feeds can
  read 'Unmatched' (closed stores), so it is not used to assign the unit.

  ── Currency ────────────────────────────────────────────────────────────────
  Column is named sales_usd. Sephora CA sales per unit is about 99% of
  retail_price, which equals the jm.com USD list price; the retailer confirmed on
  2026-11-04 that all sales are reported in USD, CA included. Shopify SKUs (e.g. JFA2-01-0002) do NOT match
  jm_sku (e.g. 4599), and jm_sku is not unique, so the Shopify columns come from
  sephora_shopify_sku_map, which matches on UPC. shopify_match says how: upc,
  override (hand-mapped), retailer_only (jm.com never carried it: kits, Canada-only
  formulas) or none (not looked at yet; fails a test).
════════════════════════════════════════════════════════════════════════════════
*/

with src as (

    select * from {{ source('s3_retail_raw', 'sephora_product_daily') }}

)

select
    date,
    week_start_date,
    week_end_date,
    split_part(_source_key, '_', 1) || '_' || split_part(_source_key, '_', 2) as business_unit,
    upper(split_part(_source_key, '_', 2))                                    as country,
    location_type,

    channel_sku,
    src.upc,
    jm_sku,
    brand,
    product_name,
    collection,
    subclass,
    season_code,
    root_status,
    retail_price,
    category,
    beauty_category,
    franchise,
    size_group,
    fragrance,

    case when sales_usd is null then 0 else 1 end as is_reported,
    coalesce(sales_usd, 0)                        as sales,
    coalesce(units, 0)                            as units,

    m.shopify_variant_id,
    m.shopify_product_id,
    m.shopify_sku,
    m.shopify_product_title,
    m.shopify_variant_name,
    m.match_method                                as shopify_match,

    delivered_at_utc,
    _source_file
from src
left join {{ ref('sephora_shopify_sku_map') }} m
    on m.upc = src.upc
