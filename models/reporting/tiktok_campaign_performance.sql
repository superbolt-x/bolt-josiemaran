{{ config (
    alias = target.database + '_tiktok_campaign_performance'
)}}

SELECT 
campaign_name,
campaign_id,
campaign_status,
campaign_type_default,
date,
date_granularity,
cost as spend,
impressions,
clicks,
complete_payment as purchases,
total_complete_payment_rate as revenue,
web_event_add_to_cart as atc
FROM {{ ref('tiktok_performance_by_campaign') }}
