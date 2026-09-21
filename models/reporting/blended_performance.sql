{{ config (
    alias = target.database + '_blended_performance'
)}}

/*
════════════════════════════════════════════════════════════════════════════════
  josiemaran_blended_performance
════════════════════════════════════════════════════════════════════════════════

  GRAIN  one row per  channel × segment × business_line × market × order_type
                      × campaign_id × campaign_name × date × date_granularity

         A campaign normally produces ONE row per date. The exception is a
         campaign SPLIT ACROSS SEGMENTS at adset level, which produces one row
         per segment — see "Adset-level segments" below.

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
      Sephora US Collab     1 Meta + 1 Meta ADSET
      Sephora CA Traffic    1 Meta + 2 TikTok
      Sephora CA Collab     1 Meta + 1 Meta ADSET
      Sephora @ Kohls       1 Meta

  ── Adset-level segments ────────────────────────────────────────────────────
  Campaign 120250632750520303 ("Sephora Collab - Purchase - Catch All") holds
  a US adset and a CA adset that belong to DIFFERENT segments. A campaign_id →
  segment map cannot express that, so seeds/campaign_segments.csv carries an
  optional adset_id: blank maps the whole campaign (every other row), non-blank
  maps one adset. Meta therefore reads at ADSET grain, resolves the segment per
  adset in `meta`, and collapses straight back to campaign grain — so only a
  split campaign yields more than one row, and every other campaign is
  byte-identical to before.

  gen_segment_macro.py REFUSES a seed that maps one campaign both as a whole
  and by adset. That is not stylistic: with both present, one spend row matches
  two mapping rows and the campaign silently double-counts. Enforcing it at
  edit time is why the join below needs no precedence logic.

  Two Redshift landmines are load-bearing here and should not be "cleaned up":
  the mapping is INLINED at each join site rather than shared as a CTE, and a
  campaign-level row carries adset_id = '' rather than NULL — `s.adset_id is
  null` in a join predicate over that UNION ALL makes the planner fail with a
  bare "Assert".

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

-- ─── PAID ───────────────────────────────────────────────────────────────────

meta_base as (

    /*  ADSET grain, not campaign grain — and this is load-bearing.

        Campaign 120250632750520303 ("Sephora Collab - Purchase - Catch All")
        holds a US adset and a CA adset that belong to DIFFERENT report
        segments. A campaign_id → segment map physically cannot express that,
        so the mapping has to resolve per adset. The rows collapse straight
        back to campaign grain in `meta` below, so the table's output grain is
        unchanged except that a split campaign yields one row per segment.

        Verified equivalent to the campaign table it replaces, 2026-09-01..20:
        7 of 8 campaigns match to the cent; the eighth differs by $0.27 on
        $14,905 (0.002%, 5 clicks of 24,979 — a deleted ad). History is
        identical (both from 2023-07-18), so nothing historical shifts.      */

    select
        campaign_id::varchar  as campaign_id,
        campaign_name,
        adset_id::varchar     as adset_id,
        adset_name,
        date,
        date_granularity,
        sum(spend)            as spend,
        sum(impressions)      as impressions,
        sum(link_clicks)      as clicks,
        sum(purchases)        as paid_purchases,
        sum(revenue)          as paid_revenue,
        sum(add_to_cart)      as paid_add_to_cart
    from {{ source('reporting', 'josiemaran_facebook_performance_by_ad') }}
    group by 1, 2, 3, 4, 5, 6

),

meta as (

    /*  Resolves the segment at ADSET grain, then collapses back to campaign
        grain. For every campaign mapped as a whole this is a no-op — all its
        adsets carry the same segment and the same campaign_name, so they
        re-aggregate into exactly the single row this CTE produced before.
        A split campaign is the only case that yields more than one row, one
        per segment, which is the point.

        The join to segment_map needs no precedence logic because
        gen_segment_macro.py refuses a seed that maps one campaign both as a
        whole and by adset — so `s.adset_id = '' or s.adset_id = m.adset_id`
        can never match two mapping rows for the same spend row. That invariant
        is enforced at edit time rather than papered over here.

        campaign_name carries the adset name appended when the match was
        adset-level, so the Campaigns tab can tell the two halves of a split
        campaign apart instead of showing the same label twice.              */

    select
        'Meta'                  as channel,
        'meta'                  as platform,
        m.campaign_id,

        case when max(nullif(m.mapped_adset, '')) is not null
             then max(m.campaign_name) || ' — ' || max(m.adset_name)
             else max(m.campaign_name) end          as campaign_name,

        max(m.map_segment)       as map_segment,
        max(m.map_business_line) as map_business_line,
        bool_or(m.map_dtc_overall) as map_dtc_overall,

        m.date,
        m.date_granularity,
        sum(m.spend)              as spend,
        sum(m.impressions)        as impressions,
        sum(m.clicks)             as clicks,
        sum(m.paid_purchases)     as paid_purchases,
        sum(m.paid_revenue)       as paid_revenue,
        sum(m.paid_add_to_cart)   as paid_add_to_cart,
        sum(m.cs_purchases)       as cs_purchases,
        sum(m.cs_revenue)         as cs_revenue,
        sum(m.cs_offline_purchases) as cs_offline_purchases,
        sum(m.cs_add_to_cart)     as cs_add_to_cart

    from (
        select
            b.campaign_id,
            b.campaign_name,
            b.adset_id,
            b.adset_name,
            b.date,
            b.date_granularity,
            b.spend, b.impressions, b.clicks,
            b.paid_purchases, b.paid_revenue, b.paid_add_to_cart,
            cs.cs_purchases,
            cs.cs_revenue,
            cs.cs_offline_purchases,
            cs.cs_add_to_cart,
            s.segment        as map_segment,
            s.business_line  as map_business_line,
            s.dtc_overall    as map_dtc_overall,
            s.adset_id       as mapped_adset
        from meta_base b
        left join {{ ref('facebook_catalog_segment_performance') }} cs
            on  cs.campaign_id      = b.campaign_id
            and cs.adset_id         = b.adset_id
            and cs.date             = b.date
            and cs.date_granularity = b.date_granularity
        -- Inlined, not a shared `segment_map` CTE. Redshift's planner throws a
        -- bare "Assert" the moment this mapping is a CTE referenced twice with
        -- one of the references carrying a predicate in a join condition — the
        -- same landmine that forced the single full outer join in paid_ga4
        -- below. The macro emits literal SQL, so inlining it at each use site
        -- costs ~17 duplicated lines in the compiled output and nothing else.
        left join ( {{ jm_campaign_segments() }} ) s
            on  s.platform    = 'meta'
            and s.campaign_id = b.campaign_id
            and (s.adset_id = '' or s.adset_id = b.adset_id)
    ) m

    -- Grouping on the RESOLVED segment is what splits the catch-all campaign
    -- into its US and CA halves while leaving every other campaign at one row.
    group by m.campaign_id, m.date, m.date_granularity,
             m.map_segment, m.map_business_line, m.map_dtc_overall

),

google as (

    select
        'Google'                as channel,
        'google'                as platform,
        campaign_id::varchar    as campaign_id,
        campaign_name,
        -- Google and TikTok resolve their segment from the campaign-level join
        -- in `paid` below, as they always have; only Meta pre-resolves, because
        -- only Meta has a campaign that spans two segments. Positional NULLs
        -- keep the three branches union-compatible.
        cast(null as varchar(64)) as map_segment,
        cast(null as varchar(16)) as map_business_line,
        cast(null as boolean)     as map_dtc_overall,
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
    -- 1-9, not 1-6: the three map_* passthrough columns sit between
    -- campaign_name and date, so the positions after them all shifted.
    group by 1, 2, 3, 4, 5, 6, 7, 8, 9

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
        cast(null as varchar(64))   as map_segment,
        cast(null as varchar(16))   as map_business_line,
        cast(null as boolean)       as map_dtc_overall,
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
    group by 1, 2, 3, 4, 5, 6, 7, 8, 9

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
                 and g.session_campaign_id ~ '^[0-9]+$'
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

paid_ga4 as (

    /*  ONE full outer join, so `paid_union` and `ga4` are each referenced
        EXACTLY ONCE in this model.

        The previous shape referenced both twice — once inside a join predicate
        and once as a FROM (paid LEFT JOIN ga4, then ga4 anti-joined back
        against paid_union). Redshift rejects that outright:

            This type of correlated subquery pattern is not supported
            due to internal error

        Every piece ran fine in isolation against the warehouse; it is the
        double reference the planner will not take. A full outer join gives
        both sides in one pass: matched rows carry spend AND ga4, GA4-only rows
        arrive with p.* NULL, and `has_paid` tells them apart. No anti-join.

        NULL campaign_id never equals NULL, so GA4 'Other' rows land on the
        GA4-only side exactly as they did before.                            */

    select
        coalesce(p.platform,         g.platform)         as platform,
        coalesce(p.campaign_id,      g.campaign_id)      as campaign_id,
        coalesce(p.date,             g.date)             as date,
        coalesce(p.date_granularity, g.date_granularity) as date_granularity,
        p.platform is not null                           as has_paid,

        p.channel,
        p.campaign_name,
        p.map_segment,
        p.map_business_line,
        p.map_dtc_overall,
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
        g.ga4_revenue

    from paid_union p
    full outer join ga4 g
        on  g.platform         = p.platform
        and g.campaign_id      = p.campaign_id
        and g.date             = p.date
        and g.date_granularity = p.date_granularity

),

paid as (

    /*  Paid rows and GA4-only rows in one select, keyed off has_paid. They
        share an identical column set, so splitting them cost a second
        reference to the join for nothing.

        A GA4-only row with a non-NULL campaign_id is a campaign that drove
        sessions in a period it had no spend. 'Unattributed Paid' still fits —
        paid source, not attached to spend — and it keeps GA4 reconciling
        exactly against the raw table.                                       */

    select
        case when pg.has_paid then pg.channel else 'GA4' end   as channel,

        -- map_* is Meta's adset-aware resolution, already done upstream; `s`
        -- is the campaign-level join Google and TikTok still use. Meta never
        -- falls through to `s`, so the two can never disagree.
        case when pg.has_paid then coalesce(pg.map_segment, s.segment, 'Unmapped')
             when pg.platform = 'other' then 'Other'
             else 'Unattributed Paid' end                      as segment,

        case when pg.has_paid
                  then coalesce(pg.map_business_line, s.business_line, 'Unmapped')
             else 'DTC' end                                    as business_line,

        case when pg.has_paid
                  then coalesce(pg.map_dtc_overall, s.dtc_overall, false)
             else false end                                    as in_dtc_overall,

        case when pg.has_paid
                  then {{ jm_market_from_segment("coalesce(pg.map_segment, s.segment, 'Unmapped')") }}
             else 'Unknown' end                                as market,

        cast(null as varchar(16))      as order_type,
        pg.campaign_id,
        pg.campaign_name,
        pg.date,
        pg.date_granularity,

        pg.spend,
        pg.impressions,
        pg.clicks,
        pg.paid_purchases,
        pg.paid_revenue,
        pg.paid_add_to_cart,

        pg.cs_purchases,
        pg.cs_revenue,
        pg.cs_offline_purchases,
        pg.cs_add_to_cart,

        pg.ga4_sessions,
        pg.ga4_purchases,
        pg.ga4_revenue,

        cast(null as bigint)           as shopify_orders,
        cast(null as bigint)           as shopify_first_orders,
        cast(null as bigint)           as shopify_repeat_orders,
        cast(null as bigint)           as shopify_new_customers,
        cast(null as double precision) as shopify_gross_sales,
        cast(null as double precision) as shopify_total_sales,
        cast(null as double precision) as shopify_discounts

    from paid_ga4 pg
    left join ( {{ jm_campaign_segments() }} ) s
        on  s.platform    = pg.platform
        and s.campaign_id = pg.campaign_id
        -- CAMPAIGN-LEVEL rows only. Adset-level rows are Meta's, and Meta has
        -- already resolved them upstream in `meta` — matching them again here
        -- does not change any value (the coalesce above prefers the resolved
        -- one) but it DUPLICATES THE ROW: a campaign split across two segments
        -- has two mapping rows, so each of its two resolved rows matched both
        -- and the campaign's spend came out exactly 2x. Every other campaign
        -- was unaffected, which is what made it look like a plausible increase
        -- rather than an obvious break.
        and s.adset_id = ''

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
select * from site
