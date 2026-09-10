/*
    Sephora COLLAB spend with no catalog-segment feedback is unmeasurable
    spend — but ONLY Collab. Traffic-objective campaigns (US/CA Traffic,
    @ Kohls) never emit catalog-segment rows, for any campaign, ever: the
    @ Kohls Traffic campaign has run since 2025-09 with $281k of lifetime
    spend and exactly 0 lifetime catalog purchases. That isn't a config
    gap, it's how Traffic-objective campaigns behave — catalog-segment
    tracking is tied to the Purchase objective. An earlier version of this
    test summed ALL Sephora Meta spend and was guaranteed to fire once
    Traffic campaigns became a large share of it, flagging normal behavior
    as an emergency.

    Scoped to segment IN ('Sephora US Collab', 'Sephora CA Collab') — the
    only campaigns where catalog feedback is actually expected — so this
    now only fires on a REAL linkage break, e.g. a Collab campaign rebuilt
    without the catalog partnership attached.

    Fails when >20% of trailing-30-day Collab spend has zero catalog-segment
    purchases attached.
*/

with trailing_30d as (
    select
        sum(spend)                                                       as collab_spend,
        sum(case when coalesce(cs_purchases, 0) = 0 then spend else 0 end) as unmeasured_spend
    from {{ ref('blended_performance') }}
    where date_granularity = 'day'
      and business_line = 'Sephora'
      and channel = 'Meta'
      and segment in ('Sephora US Collab', 'Sephora CA Collab')
      and date >= dateadd(day, -30, current_date)
)

select
    collab_spend,
    unmeasured_spend,
    round(100.0 * unmeasured_spend / nullif(collab_spend, 0), 1) as pct_unmeasured
from trailing_30d
where unmeasured_spend / nullif(collab_spend, 0) > 0.20
