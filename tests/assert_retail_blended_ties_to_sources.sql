-- Retail totals in retail_blended_performance must equal the retail models, and spend
-- the day rows of blended_performance, at every granularity. Returns the mismatches.
with t as (
    select business_unit, date_granularity,
           sum(retailer_sales) as retail_sales, sum(spend) as spend
    from {{ ref('retail_blended_performance') }}
    group by 1, 2
),
src_retail as (
    select business_unit, sum(sales) as sales from {{ ref('sephora_sales_daily') }} group by 1
    union all
    select business_unit, sum(sales) from {{ ref('kohls_sales_weekly') }} group by 1
),
src_spend as (
    select case segment
               when 'Sephora US Traffic' then 'sephora_us' when 'Sephora US Collab' then 'sephora_us'
               when 'Sephora CA Traffic' then 'sephora_ca' when 'Sephora CA Collab' then 'sephora_ca'
               when 'Sephora @ Kohls' then 'sephora_kohls' end as business_unit,
           sum(spend) as spend
    from {{ ref('blended_performance') }}
    where business_line = 'Sephora' and date_granularity = 'day'
    group by 1
)
select t.business_unit, t.date_granularity, t.retail_sales, r.sales, t.spend, s.spend as src_spend
from t
join src_retail r on r.business_unit = t.business_unit
join src_spend s on s.business_unit = t.business_unit
where abs(t.retail_sales - r.sales) > 1
   or abs(t.spend - s.spend) > 0.01
