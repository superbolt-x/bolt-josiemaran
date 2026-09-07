{{ config (
    enabled = false,
    alias = target.database + '_bingads_campaign_performance'
)}}

/*
    DISABLED — Bing Ads is not live.

    Bing is not a live channel for Josie Maran. No `bingads_*` table exists
    in the warehouse.

    Left in the repo rather than deleted so the mapping is recoverable if the
    channel is switched on. `enabled = false` keeps it out of `dbt run` /
    `dbt build` instead of failing on a missing source at runtime.
*/

SELECT 
account_id,
campaign_name,
campaign_id,
campaign_status,
campaign_type_default,
date,
date_granularity,
spend,
impressions,
clicks,
conversions as purchases,
revenue,
view_through_conversions
FROM {{ ref('bingads_performance_by_campaign') }}
