/*
════════════════════════════════════════════════════════════════════════════════
  JM – Data Health                               → Gsheet tab: data_health
════════════════════════════════════════════════════════════════════════════════
  Pin this above the report. Every issue found while building this model would
  have been caught by one of these four checks.

    freshness              last day present per channel. Lag varies by sync
                           behind Meta and Shopify, so any card mixing them in
                           the current week under-reports Google.
    catalog-feedback       Sephora spend with no catalog-segment rows. FAILING
                           NOW: the new `SB - US/CA - Sephora … Traffic` campaigns
                           carry ~92% of live Sephora spend and emit nothing,
                           while the legacy collab campaigns still report daily.
                           Kohl's traffic and the retired Engagement campaign
                           have never emitted any ($354,678 lifetime).
    tagging                share of trailing-90d spend in 'Unclassified', and
                           spend still landing in market 'Unknown'.
    zero-conversion        spend with no conversions in EITHER family.
*/

with freshness as (
    select
        'freshness'                                     as check_name,
        channel                                         as subject,
        max(date)::varchar                              as value,
        datediff(day, max(date), current_date)::varchar || ' days behind' as detail,
        case when datediff(day, max(date), current_date) > 3 then 'FAIL' else 'OK' end as status
    from reporting.josiemaran_blended_performance
    where date_granularity = 'day'
    group by 1, 2
),

catalog_feedback as (
    select
        'catalog-feedback'                              as check_name,
        meta_segment                                    as subject,
        round(100.0 * sum(case when coalesce(cs_purchases, 0) = 0 then spend else 0 end)
                    / nullif(sum(spend), 0), 1)::varchar || '% unmeasured' as value,
        '$' || round(sum(spend))::varchar || ' spend, '
             || round(sum(coalesce(cs_purchases, 0)))::varchar || ' cs purchases' as detail,
        case when sum(case when coalesce(cs_purchases, 0) = 0 then spend else 0 end)
                / nullif(sum(spend), 0) > 0.20 then 'FAIL' else 'OK' end as status
    from reporting.josiemaran_blended_performance
    where date_granularity = 'day'
      and business_line = 'Sephora'
      and channel = 'Meta'
      and date >= dateadd(day, -30, current_date)
    group by 1, 2
),

tagging as (
    select
        'tagging'                                       as check_name,
        'Unclassified business_line (90d)'              as subject,
        round(100.0 * sum(case when business_line = 'Unclassified' then spend else 0 end)
                    / nullif(sum(spend), 0), 2)::varchar || '%' as value,
        '$' || round(sum(case when business_line = 'Unclassified' then spend else 0 end))::varchar as detail,
        case when sum(case when business_line = 'Unclassified' then spend else 0 end)
                / nullif(sum(spend), 0) > 0.01 then 'FAIL' else 'OK' end as status
    from reporting.josiemaran_blended_performance
    where date_granularity = 'day' and date >= dateadd(day, -90, current_date)

    union all

    select
        'tagging',
        'Unknown market (90d)',
        round(100.0 * sum(case when market = 'Unknown' then spend else 0 end)
                    / nullif(sum(spend), 0), 2)::varchar || '%',
        '$' || round(sum(case when market = 'Unknown' then spend else 0 end))::varchar,
        case when sum(case when market = 'Unknown' then spend else 0 end)
                / nullif(sum(spend), 0) > 0.05 then 'FAIL' else 'OK' end
    from reporting.josiemaran_blended_performance
    where date_granularity = 'day' and date >= dateadd(day, -90, current_date)
),

zero_conversion as (
    select
        'zero-conversion'                               as check_name,
        business_line || ' – ' || channel               as subject,
        '$' || round(sum(spend))::varchar               as value,
        round(sum(coalesce(paid_purchases, 0)))::varchar || ' paid + '
            || round(sum(coalesce(cs_purchases, 0)))::varchar || ' cs purchases' as detail,
        case when sum(spend) > 1000
              and sum(coalesce(paid_purchases, 0)) + sum(coalesce(cs_purchases, 0)) = 0
             then 'FAIL' else 'OK' end                  as status
    from reporting.josiemaran_blended_performance
    where date_granularity = 'day'
      and channel <> 'Shopify'
      and date >= dateadd(day, -30, current_date)
    group by 1, 2
)

select * from freshness
union all select * from catalog_feedback
union all select * from tagging
union all select * from zero_conversion
order by status desc, check_name, subject
