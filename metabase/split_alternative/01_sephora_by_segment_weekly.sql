/*
════════════════════════════════════════════════════════════════════════════════
  JM – Sephora Performance by Segment (Weekly)   → Gsheet tab: data_sephora_wk
════════════════════════════════════════════════════════════════════════════════
  The Sephora business ($57.2M of the $75M 2026 plan), on the four segments it
  is managed as: US Traffic, US Collab, CA Traffic, CA Collab.

  READ THE METRIC NAMES. Sephora converts on SEPHORA's pixel against Sephora's
  catalog segment, so `paid_purchases` is near-zero for this whole business (18
  purchases on $566,802 of 2026 spend) and Shopify sees nothing at all. Every
  conversion column here is cs_* — catalog segment actions. Do not put paid_* or
  shopify_* on a Sephora slide.

  Traffic and Collab are separate rows and must stay separate. Lifetime:
  Collab spends 4.8% of Traffic's budget for 60% more purchases at 1/33rd the
  CPA. A combined "Meta Sephora" line hides the only decision on this account.

  One GROUPING SETS pass, no template tags (so the card can be published as a
  public CSV for IMPORTDATA), weeks from the warehouse's native Monday grain.
*/

with f as (

    select *
    from reporting.josiemaran_blended_performance
    where date_granularity = 'week'
      and business_line = 'Sephora'
      and channel = 'Meta'
      and date >= date_trunc('week', current_date) - interval '13 week'
      and date <  date_trunc('week', current_date)      -- exclude in-progress week

),

agg as (

    select
        date                                    as period_start,
        grouping(meta_segment)                  as g_segment,
        grouping(market)                        as g_market,
        meta_segment,
        market,
        sum(spend)                              as spend,
        sum(impressions)                        as impressions,
        sum(clicks)                             as clicks,
        sum(cs_purchases)                       as cs_purchases,
        sum(cs_revenue)                         as cs_revenue,
        sum(cs_offline_purchases)               as cs_offline_purchases,
        sum(cs_add_to_cart)                     as cs_add_to_cart
    from f
    group by grouping sets (
        (date),                                 -- Sephora total
        (date, market),                         -- Sephora US / CA
        (date, meta_segment)                    -- US Traffic, US Collab, CA Traffic, CA Collab, …
    )

),

labelled as (

    select
        period_start,
        case
            when g_segment = 1 and g_market = 0 then 'Sephora – ' || market
            when g_segment = 1                  then 'Sephora – Total'
            else meta_segment
        end                                     as row_label,
        coalesce(market, 'All')                  as market,
        g_segment,
        spend, impressions, clicks,
        cs_purchases, cs_revenue, cs_offline_purchases, cs_add_to_cart
    from agg

)

select
    row_label,
    market,
    to_char(period_start, 'IYYY-"W"IW')                         as period_label,
    period_start,
    row_label || ' | ' || to_char(period_start, 'IYYY-"W"IW')   as lookup_key,

    -- ── Spend & delivery ───────────────────────────────────────────────────
    round(spend, 2)                                             as spend,
    impressions,
    clicks,
    case when impressions > 0 then round(spend / impressions * 1000, 2) end    as cpm,
    case when impressions > 0 then round(clicks::numeric / impressions, 4) end as ctr,
    case when clicks      > 0 then round(spend / clicks, 2) end                as cpc,

    -- ── Sephora conversions: catalog segment ONLY ──────────────────────────
    round(cs_purchases, 0)                                      as cs_purchases,
    round(cs_revenue, 2)                                        as cs_revenue,
    case when spend        > 0 then round(cs_revenue / spend, 2) end       as cs_roas,
    case when cs_purchases > 0 then round(spend / cs_purchases, 2) end     as cs_cpa,
    case when cs_purchases > 0 then round(cs_revenue / cs_purchases, 2) end as cs_aov,
    case when clicks       > 0 then round(cs_purchases::numeric / clicks, 4) end as cs_cvr,
    round(cs_add_to_cart, 0)                                    as cs_add_to_cart,

    -- ── In-store share. 62% for US Traffic vs 7% for US Collab: traffic
    --    drives footfall, collab drives sephora.com. Judging traffic on online
    --    ROAS alone understates it — though 0.04 is still 0.04.
    round(cs_offline_purchases, 0)                              as cs_instore_purchases,
    case when cs_purchases > 0
         then round(cs_offline_purchases::numeric / cs_purchases, 4) end   as pct_instore,

    /*  TRUE when this row has catalog-segment feedback. FALSE means the spend
        is real and the Sephora conversions are unmeasurable — currently the
        case for the new SB traffic campaigns, Kohl's traffic and the retired
        Engagement campaign ($354,678 lifetime with no cs data at all).       */
    coalesce(cs_purchases, 0) > 0 or coalesce(cs_add_to_cart, 0) > 0 as has_catalog_feedback

from labelled
where coalesce(spend, 0) > 0
order by period_start desc, g_segment desc, row_label
