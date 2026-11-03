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
    upc            exactly one Shopify variant carries this barcode (the normal case)
    override       the UPC is not on any Shopify variant, but the `overrides` CTE
                   below ties it to one by Shopify sku (same product, size and
                   price, different UPC: Sephora has re-labelled it)
    retailer_only  listed in `overrides` with no Shopify sku: jm.com has never sold
                   it (Sephora holiday kits, the Canada-only SPF formulas, ...).
                   Intentionally unmapped; the test does not flag it.
    none           no Shopify variant has it and nobody has looked yet. A SKU with
                   positive Sephora sales and match_method none fails
                   assert_sephora_sales_are_mapped_to_shopify, so a new Sephora-only
                   product is caught instead of silently missing from product
                   comparisons. Resolve it by adding a row to `overrides`.

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

-- UPCs that cannot be matched on barcode. shopify_sku set = same product under a
-- different UPC (checked on name, size and list price); NULL = retailer-only.
-- Reviewed 2026-11-03 against the full Sephora history.
overrides as (

    select '840049913066' as upc, 'JFC9-01-0002' as shopify_sku  -- Pink Algae Pro-Retinol Body Butter, Always Nude, 6 fl oz, $42
    union all
    select '840049914407', 'JFF2-01-0002'                        -- Pink Algae Pro-Retinol Moisturizer, 1.7 fl oz, $54
    union all
    select '840049916661', null                                  -- Bite, Sized Butters Holiday 2025 (kit, never on jm.com)
    union all
    select '840049913714', null                                  -- Topless Tangerine Treats Kit (kit, never on jm.com)
    union all
    select '840049915411', null                                  -- Sun Milk SPF 33 (Canada formula)
    union all
    select '840049917583', null                                  -- Fragrance Mist, In Bed, 3.38 fl oz (not on jm.com)

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
        )                                       as rn,
        row_number() over (
            partition by v.sku
            order by v.updated_at desc, v.id
        )                                       as rn_sku
    from {{ source('shopify_catalog_raw', 'product_variant') }} v
    join {{ source('shopify_catalog_raw', 'product') }} p
        on p.id = v.product_id
    where not coalesce(p._fivetran_deleted, false)

)

select
    u.upc,
    coalesce(vs.variant_id, v.variant_id)               as shopify_variant_id,
    coalesce(vs.product_id, v.product_id)               as shopify_product_id,
    coalesce(vs.sku, v.sku)                             as shopify_sku,
    coalesce(vs.product_title, v.product_title)         as shopify_product_title,
    coalesce(vs.display_name, v.display_name)           as shopify_variant_name,
    coalesce(vs.price, v.price)                         as shopify_current_list_price,
    case
        when o.upc is not null and o.shopify_sku is null then 'retailer_only'
        when vs.variant_id is not null                   then 'override'
        when v.variant_id is not null                    then 'upc'
        else 'none'
    end                                                 as match_method
from upcs u
left join overrides o
    on o.upc = u.upc
left join variants vs
    on vs.sku = o.shopify_sku
   and vs.rn_sku = 1
left join variants v
    on v.barcode = u.upc
   and v.rn = 1
   and o.upc is null
   and v.barcode is not null
   and v.barcode <> ''
