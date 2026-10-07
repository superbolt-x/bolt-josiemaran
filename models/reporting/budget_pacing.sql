{{ config (
    alias = target.database + '_budget_pacing'
)}}

/*
════════════════════════════════════════════════════════════════════════════════
  josiemaran_budget_pacing
════════════════════════════════════════════════════════════════════════════════

  GRAIN  one row per  date × business_unit × platform × campaign_key

  The client's daily BUDGET beside what was actually SPENT, so the Gsheet can
  draw the pacing chart: actual days in grey, remaining forecast days in colour.

    forecast_budget  the client's planned spend for that day. Present on EVERY
                     day of a budgeted month, including days already past — the
                     month's budget is the sum of this column, and pacing is
                     actual-to-date ÷ that sum.
    actual_spend     what the platform reports, ONLY for days that are over and
                     that the platform has synced. NULL otherwise — never 0, so
                     "not here yet" cannot be mistaken for "spent nothing".
    is_actual        1 when actual_spend is the number to draw, 0 for a day that
                     is still forecast. The chart splits each campaign into an
                     "actual" and a "forecast" series on this flag.

  Source of the budget: gsheet_raw.josie_maran_budget_forecast, loaded from the
  client's "[EXT] Josie Maran 2026 Budgets" sheet by
  budget_forecast_to_redshift.py. One row per (date, business_unit, platform,
  campaign_key); the loader guarantees that grain.

  ── Actuals come from blended_performance, not from the platform tables ─────
  It already resolves everything this would otherwise re-derive: Meta at ADSET
  grain (one campaign spans the US and CA collab adsets), Google, standard
  TikTok, and TikTok GMV Max, which has ZERO rows in the standard TikTok tables
  and exists only as its own branch there. Re-implementing those four sources
  here would be a second copy to keep in step. Checked against the pasted
  actuals in the team's working sheet over 2026-09-01..28: TikTok matched to the
  cent; Meta and Google within a few dollars a day; the larger gaps (Kohl's on
  9/9 and 9/23) were gaps in the hand-pasted numbers, not in the warehouse.

  ── A day is "actual" per PLATFORM, not per calendar ────────────────────────
  A platform's actuals run through the EARLIER of its most recent synced day
  and yesterday in the business timezone. Google was once 8 days behind the
  others; a single "yesterday" cut-off would have drawn those days as zero
  spend. Per platform, they stay forecast until the data is there. Today is
  never actual — it is still filling.

  ── Campaign → budget line ──────────────────────────────────────────────────
  jm_budget_campaigns() maps campaign_id to a budget line (generated from
  seeds/budget_campaign_map.csv; deliberately NOT campaign_segments.csv — see
  that script). One campaign (120250632750520303) holds a US and a CA adset
  that are different budget lines, so a mapping row may carry segment_match,
  which compares against blended_performance's already-resolved segment.
  gen_budget_map_macro.py refuses a mapping that maps one campaign both whole
  and per segment, so the join below can never match two rows for one spend row
  and double-count. The mapping is INLINED at each use site rather than shared
  as a CTE, for the same Redshift planner reason as in blended_performance.

  ── Not in this model on purpose ────────────────────────────────────────────
  The monthly budget total. It is the sum of forecast_budget over the month, so
  the Gsheet derives it, and a typed override lives in the sheet, not here.
  Do NOT use the budget sheet's own "Total Budget" row for it: that row leaves
  out NB PMax Campaign (its 'Google Total' is the three branded campaigns only).
*/

with

today as (

    -- The calendar date in the business timezone, from the dbt_project.yml
    -- var time_zone. getdate returns UTC, which is already "tomorrow" for the
    -- last four evening hours of an Eastern day.
    select convert_timezone('{{ var("time_zone", "US/Eastern") }}', getdate())::date as today_local

),

budget_rows as (

    select
        date                as date,
        business_unit,
        platform,
        campaign_key,
        budget              as forecast_budget
    from {{ source('gsheet_budget_raw', 'josie_maran_budget_forecast') }}

),

spend_daily as (

    select
        lower(channel)      as platform,
        campaign_id,
        segment,
        date,
        sum(spend)          as spend
    from {{ ref('blended_performance') }}
    where date_granularity = 'day'
      and channel in ('Meta', 'Google', 'TikTok')
      and date >= (select min(date) from budget_rows)
    group by 1, 2, 3, 4

),

freshness as (

    -- Last day each platform has synced, capped at yesterday. Taken over EVERY
    -- campaign on the platform, not just the mapped ones, so a paused campaign
    -- with no rows cannot make the platform look stale.
    select
        platform,
        least(max(date), (select today_local from today) - 1) as actuals_through
    from spend_daily
    group by 1

),

mapped_spend as (

    select
        m.business_unit,
        m.platform,
        m.campaign_key,
        s.date,
        sum(s.spend)        as actual_spend
    from spend_daily s
    join ( {{ jm_budget_campaigns() }} ) m
        on  m.platform    = s.platform
        and m.campaign_id = s.campaign_id
        and (m.segment_match = '' or m.segment_match = s.segment)
    group by 1, 2, 3, 4

),

joined as (

    -- Full outer, so both of these survive: a budgeted line with no spend yet
    -- (a future day, or a line that has not launched) and spend on a day that
    -- has no budget row (an unbudgeted campaign).
    select
        coalesce(b.date,          s.date)           as date,
        coalesce(b.business_unit, s.business_unit)  as business_unit,
        coalesce(b.platform,      s.platform)       as platform,
        coalesce(b.campaign_key,  s.campaign_key)   as campaign_key,
        b.forecast_budget,
        s.actual_spend
    from budget_rows b
    full outer join mapped_spend s
        on  s.date          = b.date
        and s.business_unit = b.business_unit
        and s.platform      = b.platform
        and s.campaign_key  = b.campaign_key

)

select
    j.date,
    date_trunc('month', j.date)::date                                         as month_start,
    j.business_unit,
    j.platform,
    j.campaign_key,
    k.legend_label,
    k.stack_order,
    k.forecast_color,
    k.actual_color,
    j.forecast_budget,
    case when j.date <= f.actuals_through then coalesce(j.actual_spend, 0) end as actual_spend,
    case when j.date <= f.actuals_through then 1 else 0 end                    as is_actual,
    f.actuals_through
from joined j
left join ( {{ jm_budget_keys() }} ) k
    on  k.business_unit = j.business_unit
    and k.platform      = j.platform
    and k.campaign_key  = j.campaign_key
left join freshness f
    on  f.platform = j.platform
