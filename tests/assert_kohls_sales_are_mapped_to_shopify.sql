-- Every Kohl's SKU that sold (net sales above zero over its history) must have a
-- jm.com variant to compare against, or be listed retailer_only in the overrides
-- of sephora_shopify_sku_map. A new Kohl's-only product that sells would otherwise
-- drop out of every by-product comparison without an error anywhere. Returns the
-- unmapped SKUs; the test passes when it returns none.

select
    upc,
    min(product_name)   as product_name,
    sum(sales)          as net_sales,
    sum(units)          as net_units
from {{ ref('kohls_product_sales') }}
where shopify_match = 'none'
group by 1
having sum(sales) > 0
