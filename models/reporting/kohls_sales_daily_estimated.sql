{{ config (
    alias = target.database + '_kohls_sales_daily_estimated'
)}}

/*
════════════════════════════════════════════════════════════════════════════════
  josiemaran_kohls_sales_daily_estimated
════════════════════════════════════════════════════════════════════════════════

  GRAIN  one row per  date × business_unit        (sephora_kohls)

  Kohl's sends WEEKLY figures only (Sunday to Saturday). This model spreads each
  delivered week evenly over its 7 days (sales / 7, units / 7) so Kohl's can sit
  at every granularity next to daily spend. It is an ESTIMATE, not Kohl's daily
  sales: is_estimated is always true and source_grain says 'weekly_spread'.

  What stays exact and what does not:
    * the 7 days of a week add back to the delivered week, so a week, and any
      period made of whole weeks, ties to kohls_sales_weekly
    * a single day is approximate: an even split ignores the weekday pattern
      (Sephora US stores in 2026: Saturday ~1.5x an even day, Monday/Tuesday
      ~0.8x; Kohl's is a store business too, so expect a similar shape)
    * a month, quarter or year is exact when it is made of whole weeks and
      approximate for the weeks that straddle its boundary (split by day count)

  Do not use this table for day-over-day charts. Units stay fractional on
  purpose: rounding would break the weekly total.

  Only delivered weeks get rows. A week Kohl's has not sent has no daily rows,
  so it reads as no data, not as zero.
════════════════════════════════════════════════════════════════════════════════
*/

with days as (

    select 0 as n union all select 1 union all select 2 union all select 3
    union all select 4 union all select 5 union all select 6

)

select
    (w.week_start_date + d.n)::date            as date,
    w.week_start_date,
    w.week_end_date,
    w.business_unit,

    w.sales / 7.0                              as sales,
    w.units / 7.0                              as units,

    true                                       as is_estimated,
    'weekly_spread'                            as source_grain
from {{ ref('kohls_sales_weekly') }} w
cross join days d
