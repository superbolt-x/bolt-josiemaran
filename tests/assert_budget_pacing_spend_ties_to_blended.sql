/*
    Proves the campaign -> budget-line join neither drops nor duplicates spend.

    A campaign matching two mapping rows would make one spend row count twice;
    the pacing chart would show a taller bar and nothing would error. So: over
    the last ~30 complete days, actual spend in budget_pacing must equal the
    spend blended_performance holds for the campaigns the mapping covers.

    The blended side uses EXISTS, not a join, deliberately: EXISTS cannot
    duplicate a row, so it is the independent answer the join is held to.

    The window stops at yesterday-minus-one so a platform that syncs a few hours
    late cannot fail it, and starts no earlier than the first budgeted day (the
    model has no rows before that).
*/

with win as (
    select
        greatest(
            convert_timezone('{{ var("time_zone", "US/Eastern") }}', getdate())::date - 31,
            (select min(date) from {{ source('gsheet_budget_raw', 'josie_maran_budget_forecast') }})
        ) as lo,
        convert_timezone('{{ var("time_zone", "US/Eastern") }}', getdate())::date - 2 as hi
),

modelled as (
    select coalesce(sum(p.actual_spend), 0) as model_spend
    from {{ ref('budget_pacing') }} p
    cross join win
    where p.date between win.lo and win.hi
),

blended as (
    select coalesce(sum(b.spend), 0) as blended_spend
    from {{ ref('blended_performance') }} b
    cross join win
    where b.date_granularity = 'day'
      and b.channel in ('Meta', 'Google', 'TikTok')
      and b.date between win.lo and win.hi
      and exists (
            select 1
            from ( {{ jm_budget_campaigns() }} ) m
            where m.platform    = lower(b.channel)
              and m.campaign_id = b.campaign_id
              and (m.segment_match = '' or m.segment_match = b.segment)
      )
)

select
    model_spend,
    blended_spend,
    model_spend - blended_spend as difference
from modelled
cross join blended
where abs(model_spend - blended_spend) > 0.01
