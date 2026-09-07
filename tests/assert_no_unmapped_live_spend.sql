/*
    Catches a campaign launching without being added to the ID mapping.

    Segments are assigned by campaign_id from seeds/campaign_segments.csv. A
    campaign that is not in that file gets segment 'Unmapped' and therefore
    appears on NO segment row in the report — its spend is simply absent from
    every rollup. That is the correct behaviour (better than guessing) but it
    has to be loud.

    Window is 7 days, not 30. The nine predecessors of the current structure
    all stopped spending by 2026-08-27, so a 30-day window legitimately reports
    ~$44k of retired unmapped spend and would fail for a month after every
    restructure. 7 days reflects the live account.

    Threshold $500 rather than zero: a paused campaign can trickle a few
    dollars of late-attributed spend.
*/

with recent as (
    select
        coalesce(sum(case when segment = 'Unmapped' then spend else 0 end), 0) as unmapped_spend,
        coalesce(sum(spend), 0)                                                as total_spend,
        count(distinct case when segment = 'Unmapped' then campaign_id end)    as unmapped_campaigns
    from {{ ref('blended_performance') }}
    where date_granularity = 'day'
      and channel <> 'Shopify'
      and date >= dateadd(day, -7, current_date)
)

select
    unmapped_spend,
    total_spend,
    unmapped_campaigns,
    round(100.0 * unmapped_spend / nullif(total_spend, 0), 1) as pct_unmapped
from recent
where unmapped_spend > 500
