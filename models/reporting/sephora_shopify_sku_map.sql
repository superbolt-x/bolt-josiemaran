{{ config (
    alias = target.database + '_sephora_shopify_sku_map'
)}}

/*
════════════════════════════════════════════════════════════════════════════════
  josiemaran_sephora_shopify_sku_map
════════════════════════════════════════════════════════════════════════════════

  GRAIN  one row per  Sephora UPC

  Maps every UPC Sephora has reported to the jm.com (Shopify) variant that carries
  the same barcode, so Sephora sell-through can be set beside jm.com sales by
  product: join on shopify_variant_id (it is the variant_id in
  josiemaran_shopify_daily_sales_by_order_line_item) or on shopify_product_id.

  ── The key is the UPC, NOT jm_sku ──────────────────────────────────────────
  Sephora's jm_sku and Shopify's sku are different code systems (4599 and
  JFA2-01-0001 against JFA2-01-0002), and Sephora's jm_sku is not reliable: it is
  repeated across two different UPCs (JEZ9-01-0001 is on both the Always Nude and
  the Vanilla Vibezzz 2 fl oz butters). The UPC is the Shopify barcode and agrees
  with the product name and size on every one of the first 36 matches.

  ── match_method ────────────────────────────────────────────────────────────
    upc    exactly one Shopify variant carries this barcode (the normal case)
    none   no Shopify variant has it. Today that is three Canada-only SPF
           formulas (Rev2022) that jm.com does not sell, which carry only returns.
           A SKU with positive Sephora sales and no match fails
           assert_sephora_sales_are_mapped_to_shopify, so a new Sephora-only
           product is caught instead of silently missing from product comparisons.

  If a barcode ever sits on two Shopify variants, the most recently updated one is
  taken (so the join can never fan out) and
  assert_shopify_barcodes_unique_for_sephora_upcs fails to say the pick is a guess.
  Variants of deleted products are ignored.

  shopify_current_list_price is today's jm.com price, not the price on the day of
  the sale. Use it for orientation, not for historical discount maths.

  Built from the Sephora product feed only. When the Sephora product-by-store and
  Kohl's feeds are loaded, add their UPCs to the `upcs` CTE.
════════════════════════════════════════════════════════════════════════════════
*/

with upcs as (

    select distinct upc
    from {{ source('s3_retail_raw', 'sephora_product_daily') }}
    where upc is not null

),

variants as (

    select
        v.id                                    as variant_id,
        v.product_id,
        v.sku,
        trim(v.barcode)                         as barcode,
        v.display_name,
        p.title                                 as product_title,
        v.price,
        row_number() over (
            partition by trim(v.barcode)
            order by v.updated_at desc, v.id
        )                                       as rn
    from {{ source('shopify_catalog_raw', 'product_variant') }} v
    join {{ source('shopify_catalog_raw', 'product') }} p
        on p.id = v.product_id
    where v.barcode is not null
      and trim(v.barcode) <> ''
      and not coalesce(p._fivetran_deleted, false)

)

select
    u.upc,
    v.variant_id                                as shopify_variant_id,
    v.product_id                                as shopify_product_id,
    v.sku                                       as shopify_sku,
    v.product_title                             as shopify_product_title,
    v.display_name                              as shopify_variant_name,
    v.price                                     as shopify_current_list_price,
    case when v.variant_id is null then 'none' else 'upc' end as match_method
from upcs u
left join variants v
    on v.barcode = u.upc
   and v.rn = 1
