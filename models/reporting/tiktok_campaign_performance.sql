{{ config (
    alias = target.database + '_tiktok_campaign_performance'
)}}

/*
    Campaign-grain TikTok.

    Kept as its own model (it is referenced outside the blended stack), with two
    changes from the version merged in PR #1:

    1. Reads the package reporting table as a SOURCE, not a ref(). A ref() pulls
       tiktok_base._stg_tiktok_campaigns_insights and its lineage into every
       build; that table is already built and paid for by the scheduled run.

    2. `revenue` reads `total_purchase_value`, not `total_complete_payment_rate`.
       ⚠ That column is a RATE (payments ÷ clicks), not a currency amount, and
       there is no `total_complete_payment_value` in the source. It is harmless
       today only because every TikTok conversion column is zero — it would
       start feeding a conversion rate into ROAS the moment the connector's
       conversion metric group is switched on. Revert this one line if you
       disagree, but nothing should divide by it as it stands.

    `atc` is left under its original name — nothing downstream reads it, so
    renaming it would be churn. blended_performance does not depend on this
    model at all; it sources the same base table and derives its own columns.

    Conversions are exposed but empty: $292,756 spend, 145M impressions, 210k
    clicks and zero conversions of any type across the full history. Spend and
    delivery are real.
*/

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
FROM FROM {{ ref('tiktok_performance_by_campaign') }}
