{{ config (
    enabled = false,
    alias = target.database + '_googleads_ad_performance'
)}}

/*
    DISABLED — Google Ads (ad grain) is not live.

    Not currently built — no `josiemaran_googleads_ad_performance` table exists.
    Campaign and asset-group grain are the live Google models.

    Left in the repo rather than deleted so the mapping is recoverable if the
    channel is switched on. `enabled = false` keeps it out of `dbt run` /
    `dbt build` instead of failing on a missing source at runtime.
*/

SELECT
account_id,
ad_id,
campaign_name,
campaign_id,
campaign_status,
campaign_type_default,
ad_group_name,
ad_group_id,
date,
date_granularity,
spend,
impressions,
clicks,
conversions as purchases,
conversions_value as revenue

FROM {{ ref('googleads_performance_by_ad') }}
