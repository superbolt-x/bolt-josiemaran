-- A Sephora UPC must sit on exactly one live Shopify variant. If two variants share a
-- barcode, sephora_shopify_sku_map still returns one row per UPC (the most recently
-- updated variant), but that pick is a guess and the product comparison could be
-- attributing Sephora sales to the wrong jm.com variant. Returns the ambiguous UPCs;
-- the test passes when it returns none.

select
    trim(v.barcode)  as upc,
    count(*)         as variants
from {{ source('shopify_catalog_raw', 'product_variant') }} v
join {{ source('shopify_catalog_raw', 'product') }} p
    on p.id = v.product_id
where not coalesce(p._fivetran_deleted, false)
  and trim(v.barcode) in (select upc from {{ ref('sephora_shopify_sku_map') }})
group by 1
having count(*) > 1
