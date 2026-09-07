/*
    Sephora spend with no catalog-segment feedback is unmeasurable spend.

    Only campaigns inside the Sephora CPAS/catalog partnership emit catalog
    segment rows. When a campaign is rebuilt without that linkage it keeps
    spending and silently stops reporting any Sephora purchase.

    This is live right now. The `SB - US/CA - Sephora Prospecting - Evergreen -
    Traffic - Clicks` campaigns replaced the legacy traffic campaigns around
    2026-08-25 and emit nothing, while carrying ~$12.1k of September spend —
    roughly 92% of live Sephora spend. The legacy `obj:Purchase` collab
    campaigns still report daily, so the pipeline itself is healthy.

    Fails when >20% of trailing-30-day Sephora spend has zero catalog-segment
    purchases attached.
*/

with trailing as (
    select
        sum(spend)                                                       as sephora_spend,
        sum(case when coalesce(cs_purchases, 0) = 0 then spend else 0 end) as unmeasured_spend
    from {{ ref('blended_performance') }}
    where date_granularity = 'day'
      and business_line = 'Sephora'
      and channel = 'Meta'
      and date >= dateadd(day, -30, current_date)
)

select
    sephora_spend,
    unmeasured_spend,
    round(100.0 * unmeasured_spend / nullif(sephora_spend, 0), 1) as pct_unmeasured
from trailing
where unmeasured_spend / nullif(sephora_spend, 0) > 0.20
