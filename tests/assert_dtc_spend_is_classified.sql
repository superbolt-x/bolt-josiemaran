/*
    Catches a DTC campaign that the Shopify charts would silently leave out.

    dtc_sales_vs_spend counts only campaigns that seeds/budget_campaign_map.csv
    knows about. A campaign added to the client's reporting segments
    (campaign_segments.csv) but not to that map spends real money and never shows
    on the "Gross Sales vs. paid spend" chart, with no error anywhere. Spend that is
    in NEITHER file is already caught by assert_no_unmapped_live_spend; this is the
    other half, for a campaign the segments know and the map does not.

    business_line = 'DTC' is what the segments seed assigns. GMV Max is in the map
    (with no spend_type), so it correctly does not trip this.

    14 days, $50: a paused campaign can trickle a few dollars of late spend.
*/

select
    b.channel,
    b.campaign_id,
    max(b.campaign_name)    as campaign_name,
    sum(b.spend)            as spend_last_14_days
from {{ ref('blended_performance') }} b
where b.date_granularity = 'day'
  and b.business_line = 'DTC'
  and b.channel in ('Meta', 'Google', 'TikTok')
  and b.date >= dateadd(day, -14, current_date)
  and not exists (
        select 1
        from ( {{ jm_budget_campaigns() }} ) m
        where m.platform    = lower(b.channel)
          and m.campaign_id = b.campaign_id
          and (m.segment_match = '' or m.segment_match = b.segment)
  )
group by 1, 2
having sum(b.spend) > 50
