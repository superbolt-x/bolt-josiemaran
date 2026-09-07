/*
    A paid row with no campaign_id cannot be segmented, so it is invisible to
    the entire report. This was the state of every TikTok row before the
    blended model moved from ad grain to campaign grain — $9,507, 100% of
    current TikTok spend, attributed to nothing.

    Fails on any paid spend in the last 7 days with a NULL campaign_id.
*/

select
    channel,
    date,
    sum(spend) as spend_with_no_campaign_id
from {{ ref('blended_performance') }}
where date_granularity = 'day'
  and channel <> 'Shopify'
  and campaign_id is null
  and date >= dateadd(day, -7, current_date)
group by 1, 2
having sum(spend) > 0
