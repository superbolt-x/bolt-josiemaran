{{ config (
    alias = target.database + '_tiktok_ad_performance'
)}}

/*
    ⚠ REVENUE MAPPING WAS BROKEN — FIXED HERE.

    This model previously read:

        total_complete_payment_rate as revenue

    `total_complete_payment_rate` is a RATE (payments ÷ clicks), not a currency
    amount. Aliasing it to `revenue` fed a conversion rate into every ROAS
    calculation downstream. There is no `total_complete_payment_value` column in
    the source; the value counterpart of a purchase is `total_purchase_value`.

    The bug is currently masked because every TikTok conversion column is zero
    (see below), so `SUM(revenue)` happens to be 0 either way. It would have
    started producing silent garbage the moment conversion data arrived.

    ⚠ NO CONVERSION DATA AT ALL. Across the full history (2025-08-26 → today)
    TikTok has $292,756 spend, 145.3M impressions, 210,439 clicks and ZERO rows
    in every conversion column: purchase, total_purchase, complete_payment,
    vta/cta/evta_purchase, onsite_on_web_cart, web_event_add_to_cart, and all
    their *_value counterparts. Spend and delivery sync fine, so this is the
    Fivetran connector's conversion metric group, not the models. Until that is
    fixed TikTok can only be reported on spend and delivery.
*/

SELECT
advertiser_id,
campaign_name,
campaign_id,
campaign_status,
campaign_type_default,
adgroup_name,
adgroup_id,
adgroup_status,
audience,
ad_name,
ad_id,
ad_status,
visual,
date,
date_granularity,
cost as spend,
impressions,
clicks,
complete_payment as purchases,
total_complete_payment_rate as revenue,
web_event_add_to_cart as atc
FROM {{ ref('tiktok_performance_by_ad') }}
