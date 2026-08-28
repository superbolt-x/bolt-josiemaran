{{ config (
    alias = target.database + '_facebook_campaign_performance'
)}}

SELECT
         CASE WHEN account_id = '594708350991342' THEN 'DTC'
         WHEN account_id in ('555228837680936') THEN 'Sephora'
    END AS account,
campaign_name,
campaign_id,
campaign_effective_status,
campaign_type_default,
date,
date_granularity,
spend,
impressions,
link_clicks,
add_to_cart,
purchases,
revenue
FROM {{ ref('facebook_performance_by_campaign') }}
