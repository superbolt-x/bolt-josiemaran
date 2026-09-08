{{ config (
    alias = target.database + '_blended_performance'
)}}

/*
════════════════════════════════════════════════════════════════════════════════
  josiemaran_blended_performance
════════════════════════════════════════════════════════════════════════════════

  GRAIN  one row per  channel × segment × business_line × market × order_type
                      × campaign_id × campaign_name × date × date_granularity

  ── Segments come from CAMPAIGN IDs, not campaign names ─────────────────────
  The mapping lives in seeds/campaign_segments.csv and is taken from the
  reporting deck. The account was inherited from the client and carries three
  incompatible naming conventions, the same objective spelled three ways, and
  region as us/US/ca/CA/USA — name parsing worked but it was inference. An ID
  list is the client's actual definition, so it wins.

  Seven segments, plus one rollup:

      Google Overall        4 Google campaigns          ┐ Paid DTC Overall
      Meta Overall          2 Meta campaigns            ┘ (dtc_overall = true)
      Sephora US Traffic    1 Meta + 2 TikTok
      Sephora US Collab     1 Meta
      Sephora CA Traffic    1 Meta + 2 TikTok
      Sephora CA Collab     1 Meta
      Sephora @ Kohls       1 Meta

  Anything else → segment 'Unmapped'. Deliberately visible rather than folded
  into a total: ~$2.9M of lifetime spend is historical campaigns the deck does
  not report on, and a new campaign with no mapping must show up rather than
  disappear. The Health rows report unmapped spend over the trailing 30 days.

  ── Two businesses, two conversion sources ──────────────────────────────────
  $57.2M Sephora, $17.2M JM.com in the 2026 plan. They share no conversion:

    business_line = 'Sephora'   converts on SEPHORA's pixel against Sephora's
                                catalog segment. No Shopify order, no row in
                                Meta's own purchase columns. Measured on cs_*.
    business_line = 'DTC'       converts on josiemaran.com. Measured on
                                shopify_* and paid_*.

  Read on `purchases`, the Sephora account shows 18 purchases on $566,802 of
  2026 spend. On catalog segment actions: 6,797 purchases, $274,382 since
  March 2025.

  ── Why sources, not refs ───────────────────────────────────────────────────
  Meta and Google are read from `source('reporting', …)` — the package
  reporting tables that are already built and paid for. A ref() would pull
  their whole package lineage into every build of ours; one run rebuilt
  facebook_base.facebook_performance_by_campaign_daily (50s),
  shopify_base.shopify_orders and two staging models before reaching this
  model. Sources are read-only to dbt, so `dbt run --select +blended_performance`
  builds exactly three models — this one and the two it refs — in seconds.

  The columns are derived here rather than borrowed from
  facebook_campaign_performance / googleads_campaign_performance, so this model
  does not depend on those at all.

  ── TikTok ──────────────────────────────────────────────────────────────────
  Read from tiktok_campaign_performance, NOT tiktok_ad_performance — the
  ad-grain model returns NULL campaign_id for both live TikTok campaigns
  ($9,507, 100% of current TikTok spend), which makes an ID join impossible.
  See that model's header. All TikTok is Sephora traffic; it contributes
  nothing to Paid DTC Overall.

  ── Metric families, never interchangeable ──────────────────────────────────
    spend / impressions / clicks   delivery
    paid_*                         what Meta/Google claim on their own pixel
    ga4_*                          what GA4 attributes by session source/medium
    cs_*                           Sephora purchases via catalog segment
    shopify_*                      what JM.com actually booked

  Four conversion sources for the same business, and they will not agree. That
  is expected: paid_* is platform-attributed with a view-through window, ga4_*
  is last-non-direct session attribution, shopify_* is what the store booked.
  `ga4_roas` on the DTC slides is ga4_revenue ÷ spend; `paid_roas` is
  paid_revenue ÷ spend. Show both, never add them.

  ── GA4 channel mapping ─────────────────────────────────────────────────────
    session_source_medium = 'metaads / paidsocial'  -> Meta
    session_source_medium = 'google / cpc'          -> Google
    everything else                                 -> 'Other' (email, SMS,
                                                       organic, direct,
                                                       affiliates, …)
  TikTok has no mapping yet — there are no DTC TikTok campaigns, so no GA4
  source/medium to claim. Add one here when that changes.

  Google's `session_campaign_id` IS the campaign id and joins directly. Meta's
  is `<adset_id>_v2_sNN` — the prefix is the ADSET id, so it needs
  split_part(_, '_', 1) and an adset→campaign lookup. Over 2026-08-01 → 09-07
  that resolves 44,784 of 45,147 Meta sessions (99.2%); the remainder lands in
  'Unattributed Paid' rather than being dropped.

  GA4 rows that resolve to a campaign are ATTACHED to that campaign's paid row.
  Rows that do not — 'Other', plus paid sessions whose campaign could not be
  resolved or that had no spend that day — are emitted as their own rows with
  channel 'GA4'. The two sets are disjoint, so summing ga4_revenue across the
  whole table reconciles to the GA4 table total without double counting.

  Site rows are stamped business_line 'DTC' and segment 'Site', so Sephora
  spend can never share a business line with Shopify revenue.
*/

with

segment_map as (
    {{ jm_campaign_segments() }}
),

-- ─── PAID ───────────────────────────────────────────────────────────────────

meta_base as (

    select
        campaign_id::varchar  as campaign_id,
        campaign_name,
        date,
        date_granularity,
        sum(spend)            as spend,
        sum(impressions)      as impressions,
        sum(link_clicks)      as clicks,
        sum(purchases)        as paid_purchases,
        sum(revenue)          as paid_revenue,
        sum(add_to_cart)      as paid_add_to_cart
    from {{ source('reporting', 'josiemaran_facebook_performance_by_campaign') }}
    group by 1, 2, 3, 4

),

meta as (

    select
        'Meta'                  as channel,
        'meta'                  as platform,
        m.campaign_id,
        m.campaign_name,
        m.date,
        m.date_granularity,
        m.spend, m.impressions, m.clicks,
        m.paid_purchases, m.paid_revenue, m.paid_add_to_cart,
        cs.cs_purchases,
        cs.cs_revenue,
        cs.cs_offline_purchases,
        cs.cs_add_to_cart
    from meta_base m
    left join {{ ref('facebook_catalog_segment_performance') }} cs
        on  cs.campaign_id      = m.campaign_id
        and cs.date             = m.date
        and cs.date_granularity = m.date_granularity

),

google as (

    select
        'Google'                as channel,
        'google'                as platform,
        campaign_id::varchar    as campaign_id,
        campaign_name,
        date,
        date_granularity,
        sum(spend)                          as spend,
        sum(impressions)                    as impressions,
        sum(clicks)                         as clicks,
        -- `conversions`/`conversions_value` are the correct headline mapping:
        -- the account is run to a deliberate 1,000% tROAS on branded search and
        -- reconciles at 0.24x store orders on a window where both sources are
        -- healthy. Derived here so this model does not depend on
        -- googleads_campaign_performance.
        sum(conversions)                    as paid_purchases,
        sum(conversions_value)              as paid_revenue,
        sum(addtocartelevarserverside2)     as paid_add_to_cart,
        cast(null as double precision) as cs_purchases,
        cast(null as double precision) as cs_revenue,
        cast(null as double precision) as cs_offline_purchases,
        cast(null as double precision) as cs_add_to_cart
    from {{ source('reporting', 'josiemaran_googleads_performance_by_campaign') }}
    group by 1, 2, 3, 4, 5, 6

),

tiktok as (

    /*  Sourced from the package base table, not from
        josiemaran_tiktok_campaign_performance, for two reasons:

        1. That table already exists and is built elsewhere — sourcing the base
           table keeps this model independent of it and avoids a second model
           writing the same alias.
        2. Its `revenue` column maps to `total_complete_payment_rate`, which is
           a RATE, not a currency amount (there is no
           `total_complete_payment_value` in the source). Currently harmless
           because every TikTok conversion column is zero, but it would feed a
           conversion rate into ROAS the moment the connector is fixed. The
           correct value counterpart is `total_purchase_value`, used here.

        Campaign grain, not ad grain: the ad-grain model resolves campaign via
        ad_history → adgroup_history → campaign_history, and the two campaigns
        launched 2026-08-27 have insight rows but no ad_history rows, so
        campaign_id comes back NULL for $9,507 — all current TikTok spend.  */

    select
        'TikTok'                    as channel,
        'tiktok'                    as platform,
        campaign_id::varchar        as campaign_id,
        campaign_name,
        date,
        date_granularity,
        sum(cost)                   as spend,
        sum(impressions)            as impressions,
        sum(clicks)::double precision as clicks,
        sum(complete_payment)       as paid_purchases,
        sum(total_purchase_value)   as paid_revenue,   -- NOT total_complete_payment_rate
        sum(web_event_add_to_cart)  as paid_add_to_cart,
        cast(null as double precision) as cs_purchases,
        cast(null as double precision) as cs_revenue,
        cast(null as double precision) as cs_offline_purchases,
        cast(null as double precision) as cs_add_to_cart
    from {{ source('reporting', 'josiemaran_tiktok_performance_by_campaign') }}
    group by 1, 2, 3, 4, 5, 6

),

-- ─── GA4 ────────────────────────────────────────────────────────────────────

fb_adset_to_campaign as (

    /*  GA4's Meta session_campaign_id carries the ADSET id, not the campaign
        id. Verified unique: zero adsets map to more than one campaign, so
        max() is a safe collapse rather than an arbitrary pick.  */
    select
        adset_id::varchar               as adset_id,
        max(campaign_id::varchar)       as campaign_id
    from {{ source('reporting', 'josiemaran_facebook_performance_by_ad') }}
    where date_granularity = 'day'
      and adset_id is not null
    group by 1

),

ga4_daily as (

    select
        g.date,
        case g.session_source_medium
            when 'metaads / paidsocial' then 'meta'
            when 'google / cpc'         then 'google'
            else 'other'
        end                                                     as platform,
        case
            -- Google: the session campaign id IS the campaign id
            when g.session_source_medium = 'google / cpc'
                 and g.session_campaign_id similar to '[0-9]+'
                 then g.session_campaign_id
            -- Meta: prefix is the adset id -> look up its campaign
            when g.session_source_medium = 'metaads / paidsocial'
                 then a.campaign_id
        end                                                     as campaign_id,
        sum(g.sessions)                                         as ga4_sessions,
        sum(g.conversions_purchase)                             as ga4_purchases,
        sum(g.purchase_revenue)                                 as ga4_revenue
    from {{ source('ga4_raw', 'traffic_sources_session') }} g
    left join fb_adset_to_campaign a
        on  g.session_source_medium = 'metaads / paidsocial'
        and a.adset_id = split_part(g.session_campaign_id, '_', 1)
    group by 1, 2, 3

),

ga4_grains as (
    select 'day'     as date_granularity
    union all select 'week'
    union all select 'month'
    union all select 'quarter'
    union all select 'year'
),

ga4 as (

    select
        gr.date_granularity,
        {{ jm_period_start('d.date', 'gr.date_granularity') }} as date,
        d.platform,
        d.campaign_id,
        sum(d.ga4_sessions)             as ga4_sessions,
        sum(d.ga4_purchases)            as ga4_purchases,
        sum(d.ga4_revenue)              as ga4_revenue
    from ga4_daily d
    cross join ga4_grains gr
    group by 1, 2, 3, 4

),

paid_union as (
    select * from meta
    union all select * from google
    union all select * from tiktok
),

paid as (

    select
        p.channel,
        coalesce(s.segment, 'Unmapped')                     as segment,
        coalesce(s.business_line, 'Unmapped')               as business_line,
        coalesce(s.dtc_overall, false)                      as in_dtc_overall,
        {{ jm_market_from_segment("coalesce(s.segment, 'Unmapped')") }} as market,
        cast(null as varchar(16))                           as order_type,
        p.campaign_id,
        p.campaign_name,
        p.date,
        p.date_granularity,

        p.spend,
        p.impressions,
        p.clicks,
        p.paid_purchases,
        p.paid_revenue,
        p.paid_add_to_cart,

        p.cs_purchases,
        p.cs_revenue,
        p.cs_offline_purchases,
        p.cs_add_to_cart,

        g.ga4_sessions,
        g.ga4_purchases,
        g.ga4_revenue,

        cast(null as bigint)           as shopify_orders,
        cast(null as bigint)           as shopify_first_orders,
        cast(null as bigint)           as shopify_repeat_orders,
        cast(null as bigint)           as shopify_new_customers,
        cast(null as double precision) as shopify_gross_sales,
        cast(null as double precision) as shopify_total_sales,
        cast(null as double precision) as shopify_discounts

    from paid_union p
    left join segment_map s
        on  s.platform    = p.platform
        and s.campaign_id = p.campaign_id
    left join ga4 g
        on  g.platform         = p.platform
        and g.campaign_id      = p.campaign_id
        and g.date             = p.date
        and g.date_granularity = p.date_granularity

),

-- ─── GA4 rows with nowhere to attach ────────────────────────────────────────

ga4_unattached as (

    /*  Everything GA4 measured that is NOT already on a paid row: the 'Other'
        bucket (email, SMS, organic, direct, affiliates), Meta sessions whose
        adset did not resolve to a campaign, and paid campaigns that drove
        sessions on a day they had no spend.

        Disjoint from the joined set by construction, so ga4_revenue summed
        across the whole table equals the GA4 table total.  */

    select
        'GA4'                          as channel,
        case when g.platform = 'other' then 'Other'
             else 'Unattributed Paid' end as segment,
        'DTC'                          as business_line,
        false                          as in_dtc_overall,
        'Unknown'                      as market,
        cast(null as varchar(16))      as order_type,
        cast(null as varchar(64))      as campaign_id,
        cast(null as varchar(256))     as campaign_name,
        g.date,
        g.date_granularity,

        cast(null as double precision) as spend,
        cast(null as bigint)           as impressions,
        cast(null as double precision) as clicks,
        cast(null as double precision) as paid_purchases,
        cast(null as double precision) as paid_revenue,
        cast(null as double precision) as paid_add_to_cart,

        cast(null as double precision) as cs_purchases,
        cast(null as double precision) as cs_revenue,
        cast(null as double precision) as cs_offline_purchases,
        cast(null as double precision) as cs_add_to_cart,

        sum(g.ga4_sessions)            as ga4_sessions,
        sum(g.ga4_purchases)           as ga4_purchases,
        sum(g.ga4_revenue)             as ga4_revenue,

        cast(null as bigint)           as shopify_orders,
        cast(null as bigint)           as shopify_first_orders,
        cast(null as bigint)           as shopify_repeat_orders,
        cast(null as bigint)           as shopify_new_customers,
        cast(null as double precision) as shopify_gross_sales,
        cast(null as double precision) as shopify_total_sales,
        cast(null as double precision) as shopify_discounts

    from ga4 g
    where not exists (
        select 1 from paid_union p
        where p.platform         = g.platform
          and p.campaign_id      = g.campaign_id
          and p.date             = g.date
          and p.date_granularity = g.date_granularity
    )
    group by 1, 2, 3, 4, 5, 6, 7, 8, 9, 10

),

-- ─── SITE ───────────────────────────────────────────────────────────────────

site as (

    select
        'Shopify'                      as channel,
        'Site'                         as segment,
        'DTC'                          as business_line,
        false                          as in_dtc_overall,
        market,
        order_type,
        cast(null as varchar(64))      as campaign_id,
        cast(null as varchar(256))     as campaign_name,
        date,
        date_granularity,

        cast(null as double precision) as spend,
        cast(null as bigint)           as impressions,
        cast(null as double precision) as clicks,
        cast(null as double precision) as paid_purchases,
        cast(null as double precision) as paid_revenue,
        cast(null as double precision) as paid_add_to_cart,

        cast(null as double precision) as cs_purchases,
        cast(null as double precision) as cs_revenue,
        cast(null as double precision) as cs_offline_purchases,
        cast(null as double precision) as cs_add_to_cart,

        cast(null as bigint)           as ga4_sessions,
        cast(null as double precision) as ga4_purchases,
        cast(null as double precision) as ga4_revenue,

        orders                         as shopify_orders,
        first_orders                   as shopify_first_orders,
        repeat_orders                  as shopify_repeat_orders,
        new_customers                  as shopify_new_customers,
        gross_sales                    as shopify_gross_sales,
        total_sales                    as shopify_total_sales,
        discounts                      as shopify_discounts

    from {{ ref('shopify_sales_by_segment') }}

)

select * from paid
union all
select * from ga4_unattached
union all
select * from site
