{{ config (
    alias = target.database + '_tiktok_campaign_performance'
)}}

/*
    Campaign-grain TikTok, standard campaigns + GMV Max.

    Kept as its own model (it is referenced outside the blended stack).

    ── GMV Max ────────────────────────────────────────────────────────────────

    GMV Max campaigns are INVISIBLE to every standard TikTok table. Campaign
    1876696959444129 ('SB - GMV Max - Evergreen - Purchase - Catch All',
    created 2026-09-18) has zero rows in tiktok_raw.campaign_report_daily,
    campaign_history AND adgroup_history — TikTok reports this campaign type
    only through its own gmv_* endpoints, and /campaign/get/ does not return
    it either. So it has to be unioned in here; no change to the TikTok package
    would surface it, because the package's own sources never see it.

    What GMV Max does NOT report, at any grain: impressions and clicks. They
    are absent from gmv_campaign_report_daily and from
    gmv_advertiser_report_daily alike, so CPM/CTR/CPC/CVR are not derivable
    for these campaigns — not missing-for-now, not available. They are emitted
    as NULL rather than 0 so that a downstream average excludes them instead of
    silently pulling a CPM toward zero.

    `revenue` for a GMV Max row is TikTok Shop GMV against store_id
    7495649060905257667. It is NOT Shopify revenue: these orders never reach
    Shopify, so shopify_sales_by_segment can never reconcile them. Anything
    blending this into a Shopify-based ROAS is mixing two order systems and
    should say so.

    `spend` is `cost`; `net_spend` is `net_cost`, which is cost after TikTok's
    ROI-protection rebates. The campaign carries
    roi_protection_compensation_status = 'IN_EFFECT', so the two diverge for
    real (2026-09-27: cost $115.18, net $107.16). `cost` is the invoice-side
    number and stays the headline `spend`; `net_spend` is exposed alongside it
    rather than being a silent substitution.

    ── revenue column ─────────────────────────────────────────────────────────

    `revenue` reads `total_purchase_value`, NOT `total_complete_payment_rate`.
    ⚠ That column is a RATE (payments ÷ clicks), not a currency amount, and
    there is no `total_complete_payment_value` in the source. It was harmless
    while every TikTok conversion column was zero ($309,691 of spend, 145M
    impressions, zero conversions of any type across the full history — still
    true at time of writing). It stops being harmless the moment this model
    also carries GMV Max rows, because then a SUM over `revenue` adds real
    dollars to a ratio. Fixed here rather than left for later.

    `atc` is left under its original name — nothing downstream reads it, so
    renaming it would be churn.

    ── scope ──────────────────────────────────────────────────────────────────

    blended_performance does NOT depend on this model; it sources
    josiemaran_tiktok_performance_by_campaign directly and derives its own
    columns. So GMV Max reaching this table does NOT put it in the reporting
    feed, the Gsheet or the deck — that needs the same union added to
    blended_performance's tiktok CTE plus a campaign_segments.csv row.
*/

WITH standard AS (

    SELECT
        campaign_name,
        campaign_id,
        campaign_status,
        campaign_type_default,
        date,
        date_granularity,
        cost                            as spend,
        impressions,
        clicks,
        complete_payment                as purchases,
        total_purchase_value            as revenue,
        web_event_add_to_cart           as atc,
        cast(null as double precision)  as net_spend,
        cast('standard' as varchar(16)) as campaign_source
    FROM {{ ref('tiktok_performance_by_campaign') }}

),

gmv_daily AS (

    /*  The feed is zero-padded back to 2025-09-25 — a full year before the
        campaign was created. 361 of its 369 rows are all-zero placeholders.
        Without this filter they become phantom campaign rows on every date
        since then.  */
    SELECT
        campaign_id,
        stat_time_day::date as date,
        {{ get_date_parts('stat_time_day::date') }},
        cost,
        net_cost,
        gross_revenue,
        orders
    FROM {{ source('tiktok_gmv_raw', 'gmv_campaign_report_daily') }}
    WHERE cost <> 0 OR gross_revenue <> 0 OR orders <> 0

),

gmv_campaigns AS (

    /*  History table — one row per version, keyed on updated_at. Only one
        campaign with one version today, but it gains a row on every edit, so
        this dedupes now rather than fanning out later.  */
    SELECT campaign_id, campaign_name, campaign_status, gmx_max_promotion_type
    FROM (
        SELECT
            campaign_id,
            campaign_name,
            secondary_status as campaign_status,
            gmx_max_promotion_type,
            row_number() OVER (
                PARTITION BY campaign_id ORDER BY updated_at DESC) as rn
        FROM {{ source('tiktok_gmv_raw', 'gmv_max_campaign_history') }}
    )
    WHERE rn = 1

),

gmv_rollup AS (

    /*  Same five granularities the package emits for standard campaigns, and
        {{ '{{ get_date_parts() }}' }} picks up week_start: 'Sunday' from
        dbt_project.yml — so GMV Max weeks anchor identically to everything
        else. Rolling up here rather than unioning day rows alone is what
        stops these campaigns disappearing from the week/month views while
        showing up in the daily one.  */
    {%- for g in ['day','week','month','quarter','year'] %}
    SELECT
        cast('{{ g }}' as varchar(16)) as date_granularity,
        {{ g }}            as date,
        campaign_id,
        SUM(cost)          as spend,
        SUM(net_cost)      as net_spend,
        SUM(orders)        as purchases,
        SUM(gross_revenue) as revenue
    FROM gmv_daily
    GROUP BY 1, 2, 3
    {%- if not loop.last %}
    UNION ALL
    {%- endif %}
    {%- endfor %}

)

SELECT * FROM standard

UNION ALL

SELECT
    c.campaign_name,
    g.campaign_id,
    c.campaign_status,
    c.gmx_max_promotion_type        as campaign_type_default,
    g.date,
    g.date_granularity,
    g.spend,
    cast(null as bigint)            as impressions,  -- not reported for GMV Max
    cast(null as bigint)            as clicks,       -- not reported for GMV Max
    g.purchases,
    g.revenue,
    cast(null as bigint)            as atc,
    g.net_spend,
    cast('gmv_max' as varchar(16))  as campaign_source
FROM gmv_rollup g
LEFT JOIN gmv_campaigns c USING (campaign_id)
