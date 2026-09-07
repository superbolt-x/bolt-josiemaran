/*
════════════════════════════════════════════════════════════════════════════════
  JM – Campaign Detail (Weekly)                  → Gsheet tab: data_campaign_wk
════════════════════════════════════════════════════════════════════════════════
  Paid drilldown. Carries BOTH conversion families side by side and labels which
  one applies, because the right column depends on the business:

      business_line = 'Sephora'  → read cs_purchases / cs_revenue
      business_line = 'DTC'      → read paid_purchases / paid_revenue

  Grouping comes from the campaign-name macros, which handle all three naming
  conventions in this account (tagged `plat:…`, new `SB - …`, legacy `BD - …`).
  Sarah Creal's equivalent card hard-codes Meta adset IDs in the SQL:

      when adset_id in (120242454214080374, 120243821857330374) then 'Meta NPD'

  Those go stale the moment an adset is rebuilt and nothing fails loudly — the
  spend just leaves the report. Here a rebuilt campaign follows its name, and an
  unrecognised one surfaces in the data-health card instead of vanishing.
*/

select
    channel,
    business_line,
    meta_segment,
    funnel,
    market,
    campaign_name,
    to_char(date, 'IYYY-"W"IW')                                 as period_label,
    date                                                        as period_start,
    channel || ' | ' || campaign_name || ' | '
            || to_char(date, 'IYYY-"W"IW')                      as lookup_key,

    round(sum(spend), 2)                                        as spend,
    sum(impressions)                                            as impressions,
    sum(clicks)                                                 as clicks,
    case when sum(impressions) > 0 then round(sum(spend) / sum(impressions) * 1000, 2) end     as cpm,
    case when sum(impressions) > 0 then round(sum(clicks)::numeric / sum(impressions), 4) end  as ctr,
    case when sum(clicks)      > 0 then round(sum(spend) / sum(clicks), 2) end                 as cpc,

    -- DTC conversion family
    round(sum(paid_purchases), 0)                               as paid_purchases,
    round(sum(paid_revenue), 2)                                 as paid_revenue,
    case when sum(spend) > 0 then round(sum(paid_revenue) / sum(spend), 2) end   as paid_roas,
    case when sum(paid_purchases) > 0 then round(sum(spend) / sum(paid_purchases), 2) end as paid_cpa,

    -- Sephora conversion family
    round(sum(cs_purchases), 0)                                 as cs_purchases,
    round(sum(cs_revenue), 2)                                   as cs_revenue,
    case when sum(spend) > 0 then round(sum(cs_revenue) / sum(spend), 2) end     as cs_roas,
    case when sum(cs_purchases) > 0 then round(sum(spend) / sum(cs_purchases), 2) end as cs_cpa,
    round(sum(cs_offline_purchases), 0)                         as cs_instore_purchases,

    case when business_line = 'Sephora' then 'cs_*' else 'paid_*' end as read_which_metrics

from reporting.josiemaran_blended_performance
where date_granularity = 'week'
  and channel <> 'Shopify'
  and date >= date_trunc('week', current_date) - interval '9 week'
  and date <  date_trunc('week', current_date)
group by 1, 2, 3, 4, 5, 6, 7, 8, 9
having sum(spend) > 0
order by period_start desc, spend desc
