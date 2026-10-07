/*
  JM – Budget Pacing   (feeds the "Budget Pacing" and "DoD Budgets" Gsheet tabs)
  ══════════════════════════════════════════════════════════════════════════════
  Reads reporting.josiemaran_budget_pacing, built by dbt from
  models/reporting/budget_pacing.sql. Until `dbt run` has built that table, use
  metabase/generated/02_budget_pacing_standalone.sql instead: the same SELECT
  over the same model logic, compiled to run today.

  NO template tags, same as the feed card: it works as a plain CSV, and what to
  show (which month, which business unit) is chosen in the sheet, not here.

  Window: last month, this month and next month, in the business timezone.
    this month   the pacing chart (actual days grey, forecast days coloured)
    next month   the daily-budget chart shown ahead of the month starting
    last month   so the first days of a new month can still show the one that
                 just closed
  About 3 months x 18 budget lines x 30 days, a few thousand rows.

  Columns are read by NAME in the Gsheet (build_pacing_tabs.gs), never by
  position, so appending a column here cannot shift anything. is_actual is 1/0
  rather than a boolean so it survives the CSV round trip as a plain number.
*/

select
    date,
    month_start,
    business_unit,
    platform,
    campaign_key,
    legend_label,
    stack_order,
    forecast_color,
    actual_color,
    forecast_budget,
    actual_spend,
    is_actual
from reporting.josiemaran_budget_pacing
where month_start between
        date_trunc('month', dateadd(month, -1, convert_timezone('US/Eastern', getdate())))::date
    and date_trunc('month', dateadd(month,  1, convert_timezone('US/Eastern', getdate())))::date
order by month_start, business_unit, stack_order, date
