-- Every Sephora SKU that actually sold (net sales above zero over its history) must
-- have a jm.com variant to compare against. A SKU with returns only (the Canada-only
-- SPF formulas today) is allowed to be unmapped. A new Sephora-only product that sells
-- and has no Shopify match would otherwise drop out of every by-product comparison
-- without an error anywhere. Returns the unmapped SKUs; the test passes when it
-- returns none. Fix: give the Shopify variant the UPC as its barcode, or add an
-- override to sephora_shopify_sku_map.

select
    upc,
    min(product_name)   as product_name,
    sum(sales)          as net_sales,
    sum(units)          as net_units
from {{ ref('sephora_product_sales') }}
where shopify_match = 'none'
group by 1
having sum(sales) > 0
