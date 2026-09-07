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

  ── TikTok ──────────────────────────────────────────────────────────────────
  Read from tiktok_campaign_performance, NOT tiktok_ad_performance — the
  ad-grain model returns NULL campaign_id for both live TikTok campaigns
  ($9,507, 100% of current TikTok spend), which makes an ID join impossible.
  See that model's header. All TikTok is Sephora traffic; it contributes
  nothing to Paid DTC Overall.

  ── Metric families, never interchangeable ──────────────────────────────────
    spend / impressions / clicks   delivery
    paid_*                         what Meta/Google claim on their own pixel
    cs_*                           Sephora purchases via catalog segment
    shopify_*                      what JM.com actually booked

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
    from {{ ref('facebook_campaign_performance') }}
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
        sum(spend)              as spend,
        sum(impressions)        as impressions,
        sum(clicks)             as clicks,
        sum(purchases)          as paid_purchases,
        sum(revenue)            as paid_revenue,
        sum(add_to_cart)        as paid_add_to_cart,
        cast(null as double precision) as cs_purchases,
        cast(null as double precision) as cs_revenue,
        cast(null as double precision) as cs_offline_purchases,
        cast(null as double precision) as cs_add_to_cart
    from {{ ref('googleads_campaign_performance') }}
    group by 1, 2, 3, 4, 5, 6

),

tiktok as (

    select
        'TikTok'                as channel,
        'tiktok'                as platform,
        campaign_id::varchar    as campaign_id,
        campaign_name,
        date,
        date_granularity,
        spend,
        impressions,
        clicks::double precision as clicks,
        purchases               as paid_purchases,
        revenue                 as paid_revenue,
        add_to_cart             as paid_add_to_cart,
        cast(null as double precision) as cs_purchases,
        cast(null as double precision) as cs_revenue,
        cast(null as double precision) as cs_offline_purchases,
        cast(null as double precision) as cs_add_to_cart
    from {{ ref('tiktok_campaign_performance') }}

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
select * from site
