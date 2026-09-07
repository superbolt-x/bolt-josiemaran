{{ config (
    alias = target.database + '_googleads_campaign_performance'
)}}

/*
    `conversions` / `conversions_value` are the correct headline mapping and are
    left as they were.

    For the record, since an earlier draft of this work questioned them: the
    account is deliberately run to a 1,000% tROAS on branded search, and the
    numbers reconcile against the store on a window where both sources are
    healthy. Over August 2026 (Shopify order data complete, Google fresh):

        Google spend $27,481 · conversions 3,447 · value $299,870 → 1,091% ROAS
        store orders 14,627 · store gross $1,072,210
        → Google = 0.24x store orders, 0.28x store gross    ✓ plausible

    The apparent 1.50x over-attribution in that earlier draft was an artefact of
    the comparison window, which started 2026-03-25 and so included four months
    where Google was spending against Shopify order data that had not yet synced.

    Additive columns only below — nothing renamed, nothing removed.
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
conversions_value as revenue,

-- New-customer view, for acquisition CAC/ROAS. The deck's DTC priority is a
-- 70 New / 20 Engaged / 10 Existing split, which needs a new-customer numerator.
purchasenewcustomer                         as new_customer_purchases,
purchasenewcustomer_value                   as new_customer_revenue,

-- Upper funnel, for the non-brand PMax launch.
addtocartelevarserverside2                  as add_to_cart,
begincheckoutelevarserverside2              as begin_checkout,

search_impression_share,
search_budget_lost_impression_share,
search_rank_lost_impression_share
FROM {{ ref('googleads_performance_by_campaign') }}
