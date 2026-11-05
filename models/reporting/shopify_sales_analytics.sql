{{ config (
    alias = target.database + '_shopify_sales_analytics'
)}}

{#- Shopify Analytics' own sales by day, loaded from ShopifyQL by the server Shopify pipeline
    (elt/sources/shopify.py, table shopify_raw.analytics_sales_by_order_day; same model as Nestig and OneSkin).
    Shopify Analytics books an order edit or exchange on the day of the edit and a return on the day of the return;
    the order-based models (josiemaran_shopify_sales) book an order's current items on the original order date,
    so the two differ by the edits and returns made to older orders. This table matches Shopify's reports.
    Days are in the store time zone (America/Los_Angeles), as in Shopify's reports; the order-based models use US/Eastern.
    revenue = net_sales + shipping_charges (shipping_charges is net of shipping refunds), as on Nestig.
    Week starts on Monday (Redshift DATE_TRUNC). -#}

{%- set date_granularity_list = ['day','week','month','quarter','year'] -%}

WITH daily AS
    (SELECT
        day AS date,
        SUM(gross_sales) AS gross_sales,
        SUM(discounts) AS discounts,
        SUM(returns) AS returns,
        SUM(net_sales) AS net_sales,
        SUM(shipping_charges) AS shipping_charges,
        SUM(taxes) AS taxes,
        SUM(total_sales) AS total_sales
    FROM {{ source('shopify_analytics_raw', 'analytics_sales_by_order_day') }}
    GROUP BY 1
    )

{% for date_granularity in date_granularity_list %}
SELECT
    '{{ date_granularity }}' AS date_granularity,
    DATE_TRUNC('{{ date_granularity }}', date)::date AS date,
    SUM(gross_sales) AS gross_sales,
    SUM(discounts) AS discounts,
    SUM(returns) AS returns,
    SUM(net_sales) AS net_sales,
    SUM(shipping_charges) AS shipping_charges,
    SUM(taxes) AS taxes,
    SUM(total_sales) AS total_sales,
    SUM(net_sales + shipping_charges) AS revenue,
    '{{ date_granularity }}' || '_' || DATE_TRUNC('{{ date_granularity }}', date)::date AS unique_key
FROM daily
GROUP BY 1, 2
{% if not loop.last %}UNION ALL{% endif %}
{% endfor %}
