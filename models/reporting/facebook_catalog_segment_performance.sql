{{ config (
    alias = target.database + '_facebook_catalog_segment_performance',
    tags = ['jm_blended']
)}}

/*
════════════════════════════════════════════════════════════════════════════════
  josiemaran_facebook_catalog_segment_performance
════════════════════════════════════════════════════════════════════════════════

  Sephora purchase conversions for the Meta Collaborative Ads (CPAS) campaigns.

  WHY THIS IS THE ONLY PLACE THEY EXIST
  Sephora campaigns sell on sephora.com. The purchase fires on Sephora's pixel,
  against Sephora's catalog segment shared with Josie Maran — so it appears in
  NEITHER the Meta account's own purchase columns NOR in Shopify. Judged on the
  standard `purchases` column, the Sephora account looks like it converts almost
  nothing: 18 purchases on $566,802 of 2026 spend. Judged on catalog segment
  actions it has driven 6,793 purchases and $274,226 since March 2025.

  Any Sephora reporting that does not read this table is wrong by construction.

  ── The trap: action types NEST ──────────────────────────────────────────────
  This is EAV — one row per campaign × date × action_type — and the types are
  not disjoint. Measured over the full history:

      omni_purchase                        6,793   $274,226   <- headline
        offsite_conversion.fb_pixel_purchase 4,762   $202,519  (sephora.com web)
        offline_conversion.purchase          1,481    $52,774  (IN STORE)
        app_custom_event.fb_mobile_purchase    550    $18,933  (Sephora app)
                                          ───────  ─────────
                                            6,793   $274,226  ✓ exact

      `purchase` (5,312) is omni minus offline. `view_content` and
      `omni_view_content` are byte-identical, as are `add_to_cart` and
      `omni_add_to_cart`.

  So: SUM(value) GROUP BY campaign would trible-count. This model pivots named
  action types into columns so that mistake is not available downstream.

  `omni_purchase` is the right headline — it is the only one that includes the
  1,481 in-store purchases, which is a third of the offline-capable volume and
  precisely the retail impact the Sephora business is being judged on.

  ── Attribution ──────────────────────────────────────────────────────────────
  `value` = `_7_d_click` + `_1_d_view` (verified: 2,620 + 4,173 = 6,793). Both
  components are exposed because 61% of catalog-segment purchase credit here is
  1-day-view, which is worth being able to show separately.

  ── Coverage warning ─────────────────────────────────────────────────────────
  Only campaigns inside the CPAS/catalog partnership emit these rows. As of
  2026-09-07 the two legacy `obj:Purchase` collab campaigns still do; the new
  `SB - US/CA - Sephora Prospecting … Traffic - Clicks` campaigns that replaced
  the legacy traffic campaigns on ~2026-08-25 emit NOTHING, despite carrying
  ~$12.1k of September spend. See the coverage test in blended.yml.
*/

with actions as (

    select
        campaign_id,
        date,
        action_type,
        sum(value)       as cnt,
        sum(_7_d_click)  as cnt_7d_click,
        sum(_1_d_view)   as cnt_1d_view
    from {{ source('facebook_catalog_raw', 'campaigns_insights_catalog_segment_actions') }}
    group by 1, 2, 3

),

values_ as (

    select
        campaign_id,
        date,
        action_type,
        sum(value)       as val,
        sum(_7_d_click)  as val_7d_click,
        sum(_1_d_view)   as val_1d_view
    from {{ source('facebook_catalog_raw', 'campaigns_insights_catalog_segment_value') }}
    group by 1, 2, 3

),

joined as (

    select
        coalesce(a.campaign_id, v.campaign_id) as campaign_id,
        coalesce(a.date, v.date)               as date,
        coalesce(a.action_type, v.action_type)  as action_type,
        a.cnt, a.cnt_7d_click, a.cnt_1d_view,
        v.val, v.val_7d_click, v.val_1d_view
    from actions a
    full outer join values_ v
        on  a.campaign_id = v.campaign_id
        and a.date        = v.date
        and a.action_type = v.action_type

),

pivoted as (

    select
        campaign_id,
        date,

        -- ── Headline: all channels (web + app + in store) ──────────────────
        sum(case when action_type = 'omni_purchase' then cnt end)          as cs_purchases,
        sum(case when action_type = 'omni_purchase' then val end)          as cs_revenue,
        sum(case when action_type = 'omni_purchase' then cnt_7d_click end) as cs_purchases_7d_click,
        sum(case when action_type = 'omni_purchase' then cnt_1d_view end)  as cs_purchases_1d_view,
        sum(case when action_type = 'omni_purchase' then val_7d_click end) as cs_revenue_7d_click,
        sum(case when action_type = 'omni_purchase' then val_1d_view end)  as cs_revenue_1d_view,

        -- ── Channel breakdown of that headline (sums back to omni) ─────────
        sum(case when action_type = 'offsite_conversion.fb_pixel_purchase' then cnt end) as cs_web_purchases,
        sum(case when action_type = 'offsite_conversion.fb_pixel_purchase' then val end) as cs_web_revenue,
        sum(case when action_type = 'offline_conversion.purchase' then cnt end)          as cs_offline_purchases,
        sum(case when action_type = 'offline_conversion.purchase' then val end)          as cs_offline_revenue,
        sum(case when action_type = 'onsite_app_purchase' then cnt end)                  as cs_app_purchases,
        sum(case when action_type = 'onsite_app_purchase' then val end)                  as cs_app_revenue,

        -- ── Upper funnel ───────────────────────────────────────────────────
        sum(case when action_type = 'omni_add_to_cart' then cnt end)   as cs_add_to_cart,
        sum(case when action_type = 'omni_add_to_cart' then val end)   as cs_add_to_cart_value,
        sum(case when action_type = 'omni_view_content' then cnt end)  as cs_view_content,
        sum(case when action_type = 'omni_view_content' then val end)  as cs_view_content_value

    from joined
    group by 1, 2

),

grains as (
    select 'day'     as date_granularity
    union all select 'week'
    union all select 'month'
    union all select 'quarter'
    union all select 'year'
),

spined as (

    select
        g.date_granularity,
        case g.date_granularity
            when 'day'     then p.date
            when 'week'    then date_trunc('week',    p.date)::date
            when 'month'   then date_trunc('month',   p.date)::date
            when 'quarter' then date_trunc('quarter', p.date)::date
            when 'year'    then date_trunc('year',    p.date)::date
        end as date,
        p.campaign_id,
        p.cs_purchases, p.cs_revenue,
        p.cs_purchases_7d_click, p.cs_purchases_1d_view,
        p.cs_revenue_7d_click, p.cs_revenue_1d_view,
        p.cs_web_purchases, p.cs_web_revenue,
        p.cs_offline_purchases, p.cs_offline_revenue,
        p.cs_app_purchases, p.cs_app_revenue,
        p.cs_add_to_cart, p.cs_add_to_cart_value,
        p.cs_view_content, p.cs_view_content_value
    from pivoted p
    cross join grains g

)

select
    campaign_id,
    date,
    date_granularity,
    sum(cs_purchases)           as cs_purchases,
    sum(cs_revenue)             as cs_revenue,
    sum(cs_purchases_7d_click)  as cs_purchases_7d_click,
    sum(cs_purchases_1d_view)   as cs_purchases_1d_view,
    sum(cs_revenue_7d_click)    as cs_revenue_7d_click,
    sum(cs_revenue_1d_view)     as cs_revenue_1d_view,
    sum(cs_web_purchases)       as cs_web_purchases,
    sum(cs_web_revenue)         as cs_web_revenue,
    sum(cs_offline_purchases)   as cs_offline_purchases,
    sum(cs_offline_revenue)     as cs_offline_revenue,
    sum(cs_app_purchases)       as cs_app_purchases,
    sum(cs_app_revenue)         as cs_app_revenue,
    sum(cs_add_to_cart)         as cs_add_to_cart,
    sum(cs_add_to_cart_value)   as cs_add_to_cart_value,
    sum(cs_view_content)        as cs_view_content,
    sum(cs_view_content_value)  as cs_view_content_value
from spined
group by 1, 2, 3
