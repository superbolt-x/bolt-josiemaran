/*
  JM – DTC Sales vs Spend   (feeds the "Gross Sales vs Spend" Gsheet tab)
  ══════════════════════════════════════════════════════════════════════════════
  Reads reporting.josiemaran_dtc_sales_vs_spend, built by dbt from
  models/reporting/dtc_sales_vs_spend.sql. Until `dbt run` has built that table,
  use metabase/generated/03_dtc_sales_vs_spend_standalone.sql instead: the same
  SELECT over the same model logic, compiled to run today.

  NO template tags, same as the feed card. The tab shows month-to-date, and which
  month is decided in the sheet, not here.

  Window: last month and this month, in the business timezone. This month is the
  month-to-date view; last month is there so the first day of a new month can
  still show the one that just closed. One row per complete day, so about 60 rows.

  Columns are read by NAME in the Gsheet (build_sales_tab.gs), never by position.
  A spend column is blank, not 0, on a day that platform has not synced yet.
*/

select
    date,
    month_start,
    new_customer_gross_sales,
    returning_customer_gross_sales,
    gross_sales,
    new_customers,
    spend_meta,
    spend_google,
    spend_tiktok,
    spend_prospecting,
    spend_mixed,
    spend_brand,
    spend_nonbrand
from reporting.josiemaran_dtc_sales_vs_spend
where month_start >=
        date_trunc('month', dateadd(month, -1, convert_timezone('US/Eastern', getdate())))::date
order by date
