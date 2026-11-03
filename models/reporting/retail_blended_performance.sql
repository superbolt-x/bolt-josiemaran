{{ config (
    alias = target.database + '_retail_blended_performance'
)}}

/*
════════════════════════════════════════════════════════════════════════════════
  josiemaran_retail_blended_performance
════════════════════════════════════════════════════════════════════════════════

  GRAIN  one row per  business_unit × date × date_granularity
         business_unit      sephora_us | sephora_ca | sephora_kohls
         date_granularity   day | week | month | quarter | year
         date               start of the period (weeks start on Sunday)

  What the retailer says it sold, beside what we spent to drive it, at every
  granularity. A SEPARATE table from josiemaran_blended_performance: that table is
  unchanged, so nothing that reads it moves.

  ── Spend side ──────────────────────────────────────────────────────────────
  Read from josiemaran_blended_performance DAY rows, business_line = 'Sephora',
  rolled to the budget sheet's business units and then to each period:

      Sephora US Traffic, Sephora US Collab    -> sephora_us
      Sephora CA Traffic, Sephora CA Collab    -> sephora_ca
      Sephora @ Kohls                          -> sephora_kohls

  spend / impressions / clicks are delivery; cs_* are the Sephora catalog-segment
  purchases (the Sephora pixel's conversions, never Meta's own purchase columns).

  ── Retail side (retailer_*) ────────────────────────────────────────────────
  Sephora: josiemaran_sephora_sales_daily, rolled up. Kohl's: the WEEKLY figure
  spread evenly over 7 days (josiemaran_kohls_sales_daily_estimated), rolled up.
  The retailer's numbers are a separate family from paid_*, cs_*, ga4_* and
  shopify_*: never add them to any of those. Sales are net of returns; a NULL in
  Sephora's file counts as $0; Sephora CA is treated as USD.

    retailer_days_covered      days in the period the retailer has delivered
    days_in_period             calendar days in the period
    retailer_period_complete   1 when every day of the period is delivered
    retailer_includes_estimate 1 when any of the retailer_* figures rests on the
                               Kohl's weekly spread for days the week does not
                               fully cover (every Kohl's day row; a month with a
                               week straddling its edge; never a Kohl's week)
    retailer_sales_estimated   the part of retailer_sales that is such an estimate
    retail_data_through        last day the retailer has delivered, per unit

  A period with no delivered retail days has NULL retailer_* (not 0). A period
  only partly delivered (the current month, or a missing week) sums what exists:
  read retailer_period_complete before comparing it with spend.

  ── The ratio ───────────────────────────────────────────────────────────────
  sell_through_per_spend_dollar = retailer_sales / spend, only when the retail
  period is complete and spend > 0. It is NOT ROAS: Sephora sales are not
  attributed to the ads. Re-derive it from the sums when you aggregate rows.
════════════════════════════════════════════════════════════════════════════════
*/

with

grains as (
    select 'day' as date_granularity
    union all select 'week'
    union all select 'month'
    union all select 'quarter'
    union all select 'year'
),

-- ─── SPEND ──────────────────────────────────────────────────────────────────

spend_daily as (

    select
        case segment
            when 'Sephora US Traffic' then 'sephora_us'
            when 'Sephora US Collab'  then 'sephora_us'
            when 'Sephora CA Traffic' then 'sephora_ca'
            when 'Sephora CA Collab'  then 'sephora_ca'
            when 'Sephora @ Kohls'    then 'sephora_kohls'
        end                           as business_unit,
        date,
        sum(spend)                    as spend,
        sum(impressions)              as impressions,
        sum(clicks)                   as clicks,
        sum(cs_purchases)             as cs_purchases,
        sum(cs_revenue)               as cs_revenue,
        sum(cs_offline_purchases)     as cs_offline_purchases,
        sum(cs_add_to_cart)           as cs_add_to_cart
    from {{ ref('blended_performance') }}
    where business_line = 'Sephora'
      and date_granularity = 'day'
      and segment in ('Sephora US Traffic', 'Sephora US Collab',
                      'Sephora CA Traffic', 'Sephora CA Collab', 'Sephora @ Kohls')
    group by 1, 2

),

-- Rolled up from the DAY rows, not read from blended_performance's own week rows:
-- the packaged week that straddles New Year (2025-12-28) holds only its 2025 days
-- there, so Jan 1-3 2026 spend (~$21k) is missing from those week rows. From days,
-- week / month / quarter / year all add to the same total.
spend as (

    select
        d.business_unit,
        {{ jm_period_start('d.date', 'gr.date_granularity') }} as date,
        gr.date_granularity,
        sum(d.spend)                  as spend,
        sum(d.impressions)            as impressions,
        sum(d.clicks)                 as clicks,
        sum(d.cs_purchases)           as cs_purchases,
        sum(d.cs_revenue)             as cs_revenue,
        sum(d.cs_offline_purchases)   as cs_offline_purchases,
        sum(d.cs_add_to_cart)         as cs_add_to_cart
    from spend_daily d
    cross join grains gr
    group by 1, 2, 3

),

-- ─── RETAIL, daily ──────────────────────────────────────────────────────────

retail_daily as (

    select
        date, week_start_date, (week_start_date + 6)::date as week_end_date, business_unit,
        sales, sales_bm, sales_com, units, units_bm, units_com,
        false as is_estimated
    from {{ ref('sephora_sales_daily') }}
    where business_unit in ('sephora_us', 'sephora_ca')

    union all

    select
        date, week_start_date, week_end_date, business_unit,
        sales,
        cast(null as double precision), cast(null as double precision),
        units,
        cast(null as double precision), cast(null as double precision),
        is_estimated
    from {{ ref('kohls_sales_daily_estimated') }}

),

retail_through as (
    select business_unit, max(date) as retail_data_through
    from retail_daily
    group by 1
),

-- Every retail day in every period it belongs to. period_end is derived once so
-- the estimate flag and the coverage count share it.
retail_periods as (

    select
        r.business_unit,
        gr.date_granularity,
        {{ jm_period_start('r.date', 'gr.date_granularity') }} as date,
        r.date as day,
        r.week_start_date, r.week_end_date, r.is_estimated,
        r.sales, r.sales_bm, r.sales_com, r.units, r.units_bm, r.units_com
    from retail_daily r
    cross join grains gr

),

retail as (

    select
        business_unit,
        date_granularity,
        date,
        case date_granularity
            when 'day'     then date
            when 'week'    then date + 6
            when 'month'   then (dateadd(month, 1, date) - 1)::date
            when 'quarter' then (dateadd(month, 3, date) - 1)::date
            when 'year'    then (dateadd(year, 1, date) - 1)::date
        end                                       as period_end,

        sum(sales)                                as retailer_sales,
        sum(sales_bm)                             as retailer_sales_bm,
        sum(sales_com)                            as retailer_sales_com,
        sum(units)                                as retailer_units,
        sum(units_bm)                             as retailer_units_bm,
        sum(units_com)                            as retailer_units_com,
        count(distinct day)                       as retailer_days_covered,

        -- a day's figure is an estimate when its source week is not wholly inside
        -- the period: always for a day, never for a week
        max(case when is_estimated
                  and (week_start_date < date
                       or week_end_date > case date_granularity
                                              when 'day'     then date
                                              when 'week'    then date + 6
                                              when 'month'   then (dateadd(month, 1, date) - 1)::date
                                              when 'quarter' then (dateadd(month, 3, date) - 1)::date
                                              when 'year'    then (dateadd(year, 1, date) - 1)::date
                                          end)
                 then 1 else 0 end)               as retailer_includes_estimate,
        sum(case when is_estimated
                  and (week_start_date < date
                       or week_end_date > case date_granularity
                                              when 'day'     then date
                                              when 'week'    then date + 6
                                              when 'month'   then (dateadd(month, 1, date) - 1)::date
                                              when 'quarter' then (dateadd(month, 3, date) - 1)::date
                                              when 'year'    then (dateadd(year, 1, date) - 1)::date
                                          end)
                 then sales else 0 end)           as retailer_sales_estimated
    from retail_periods
    group by 1, 2, 3

),

joined as (

    select
        coalesce(s.business_unit, r.business_unit)         as business_unit,
        coalesce(s.date, r.date)                           as date,
        coalesce(s.date_granularity, r.date_granularity)   as date_granularity,

        s.spend, s.impressions, s.clicks,
        s.cs_purchases, s.cs_revenue, s.cs_offline_purchases, s.cs_add_to_cart,

        r.retailer_sales, r.retailer_sales_bm, r.retailer_sales_com,
        r.retailer_units, r.retailer_units_bm, r.retailer_units_com,
        r.retailer_days_covered,
        r.retailer_includes_estimate,
        r.retailer_sales_estimated,
        r.period_end                                       as retail_period_end
    from spend s
    full outer join retail r
        on  r.business_unit     = s.business_unit
        and r.date              = s.date
        and r.date_granularity  = s.date_granularity

)

select
    j.business_unit,
    j.date,
    j.date_granularity,

    j.spend, j.impressions, j.clicks,
    j.cs_purchases, j.cs_revenue, j.cs_offline_purchases, j.cs_add_to_cart,

    j.retailer_sales, j.retailer_sales_bm, j.retailer_sales_com,
    j.retailer_units, j.retailer_units_bm, j.retailer_units_com,

    -- the same calendar span for a day count, whether or not the retailer sent data
    case j.date_granularity
        when 'day'     then 1
        when 'week'    then 7
        when 'month'   then (dateadd(month, 1, j.date)::date - j.date)
        when 'quarter' then (dateadd(month, 3, j.date)::date - j.date)
        when 'year'    then (dateadd(year, 1, j.date)::date - j.date)
    end                                                    as days_in_period,
    coalesce(j.retailer_days_covered, 0)                   as retailer_days_covered,
    case when j.retailer_days_covered is null then 0
         when j.retailer_days_covered
              = case j.date_granularity
                    when 'day'     then 1
                    when 'week'    then 7
                    when 'month'   then (dateadd(month, 1, j.date)::date - j.date)
                    when 'quarter' then (dateadd(month, 3, j.date)::date - j.date)
                    when 'year'    then (dateadd(year, 1, j.date)::date - j.date)
                end then 1 else 0 end                      as retailer_period_complete,
    coalesce(j.retailer_includes_estimate, 0)              as retailer_includes_estimate,
    j.retailer_sales_estimated,
    t.retail_data_through,

    case when j.retailer_days_covered
              = case j.date_granularity
                    when 'day'     then 1
                    when 'week'    then 7
                    when 'month'   then (dateadd(month, 1, j.date)::date - j.date)
                    when 'quarter' then (dateadd(month, 3, j.date)::date - j.date)
                    when 'year'    then (dateadd(year, 1, j.date)::date - j.date)
                end
          and j.spend > 0
         then j.retailer_sales / j.spend
    end                                                    as sell_through_per_spend_dollar
from joined j
left join retail_through t
    on t.business_unit = j.business_unit
