{{ config (
    alias = target.database + '_facebook_ad_performance'
)}}

SELECT 
     CASE WHEN account_id = '594708350991342' THEN 'DTC'
         WHEN account_id in ('555228837680936') THEN 'Sephora'
    END AS account,
campaign_name,
campaign_id,
campaign_effective_status,
campaign_type_default,
adset_name,
adset_id,
adset_effective_status,
audience,
ad_name,
ad_id,
ad_effective_status,
visual,
copy,
format_visual,
visual_copy,
date,
date_granularity,
spend,
impressions,
link_clicks,
add_to_cart,
purchases,
revenue,

-- Attribution-window splits.
purchases_7_d_click,
revenue_7_d_click,
purchases_1_d_view,
revenue_1_d_view,

-- Shared-item (collaborative ad / catalogue) credit.
purchases_with_shared_items,
revenue_with_shared_items
FROM {{ ref('facebook_performance_by_ad') }}
