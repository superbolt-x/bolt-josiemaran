/*
    Catches a new line appearing in the client's budget sheet that
    seeds/budget_campaign_map.csv does not know about.

    budget_pacing draws each budget line in the colour and stack position the
    mapping gives it. A line with no mapping row has no colour, no label and no
    place in the stack, so the chart would render it wrong -- or not at all --
    with no error anywhere. The loader (budget_forecast_to_redshift.py) already
    blocks a tab with an UNKNOWN LABEL; this is the second half, for a label the
    loader knows but this mapping does not.

    Looks back one month so a long-retired line from an old tab cannot fail the
    build forever; anything budgeted for last month onward must be mapped.

    A fix is one line in the CSV, then scripts/gen_budget_map_macro.py.
*/

select distinct
    b.business_unit,
    b.platform,
    b.campaign_key
from {{ source('gsheet_budget_raw', 'josie_maran_budget_forecast') }} b
where b.date >= date_trunc('month', dateadd(month, -1, current_date))
  and not exists (
        select 1
        from ( {{ jm_budget_keys() }} ) k
        where k.business_unit = b.business_unit
          and k.platform      = b.platform
          and k.campaign_key  = b.campaign_key
  )
