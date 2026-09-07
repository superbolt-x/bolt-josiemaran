{{ config (
    alias = target.database + '_facebook_campaign_performance'
)}}

/*
    `account` is a display label ONLY — it is not the business line.

    $144,306 of retail spend (`temp:sephora-KOHLS`) sits inside the DTC ad
    account 594708350991342, so filtering `account = 'DTC'` does NOT isolate
    the spend that drives Shopify. Business line is derived from the campaign
    name tags in `blended_performance` via the jm_business_line() macro — use
    that, not this column.

    `account_id` is now passed through as well: the previous CASE returned NULL
    for any account id not in the two hard-coded values, which would silently
    drop a newly added account out of every report.

    Attribution windows are exposed so a report can show how much of Meta's
    claimed revenue depends on view-through credit. `purchases` / `revenue`
    remain the account default.
*/

SELECT
account_id,
     CASE WHEN account_id = '594708350991342' THEN 'DTC'
         WHEN account_id in ('555228837680936') THEN 'Sephora'
         ELSE 'Unmapped (' || account_id || ')'
    END AS account,
campaign_name,
campaign_id,
campaign_effective_status,
campaign_type_default,
date,
date_granularity,
spend,
impressions,
clicks,
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
FROM {{ ref('facebook_performance_by_campaign') }}
