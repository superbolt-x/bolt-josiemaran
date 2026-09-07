{{ config (
    alias = target.database + '_tiktok_campaign_performance'
)}}

/*
════════════════════════════════════════════════════════════════════════════════
  josiemaran_tiktok_campaign_performance
════════════════════════════════════════════════════════════════════════════════

  Campaign-grain TikTok. This is the model the blended layer reads.

  ── Why campaign grain and not tiktok_ad_performance ────────────────────────
  The ad-grain model resolves campaign via ad_history → adgroup_history →
  campaign_history. The two campaigns launched 2026-08-27 have insight rows but
  no ad_history rows yet, so the chain breaks and every hierarchy field comes
  back NULL — campaign_id, adgroup_id, ad_name — for 14 ads and $9,507 of spend.
  That was 100% of current TikTok spend arriving with no campaign attribution,
  which makes an ID-based segment mapping impossible.

  Campaign grain carries campaign_id directly, so both new campaigns resolve:

      1874691217255666  SB - Sephora Prospecting US - Evergreen - Traffic  $6,318
      1874694608225890  SB - Sephora Prospecting CA - Evergreen - Traffic  $3,189

  `tiktok_ad_performance` remains the right model for creative/ad analysis.

  ── Two fixes against the previously-built version of this table ────────────
  1. `revenue` reads `total_purchase_value`, not `total_complete_payment_rate`.
     That column is a RATE, not a currency amount; there is no
     `total_complete_payment_value` in the source. The bug is currently masked
     because every TikTok conversion column is zero, so it would have started
     producing silent garbage the moment the connector was fixed.
  2. `atc` renamed `add_to_cart`, matching every other reporting model.

  ── Conversions are all zero ────────────────────────────────────────────────
  Across the full history: $292,756 spend, 145M impressions, 210k clicks, and
  no conversions of any type. The columns are here so nothing needs changing
  when the connector's conversion metric group is switched on.

  Every TikTok campaign is Sephora traffic — there is no TikTok DTC activity, so
  TikTok contributes no rows to Paid DTC Overall.
*/

SELECT
campaign_id,
campaign_name,
campaign_status,
campaign_type_default,
date,
date_granularity,
cost                            as spend,
impressions,
clicks,
complete_payment                as purchases,
total_purchase_value            as revenue,      -- was: total_complete_payment_rate (a RATE)
web_event_add_to_cart           as add_to_cart,  -- was: atc
total_purchase,
total_purchase_value,
complete_payment,
value_per_complete_payment
FROM {{ ref('tiktok_performance_by_campaign') }}
