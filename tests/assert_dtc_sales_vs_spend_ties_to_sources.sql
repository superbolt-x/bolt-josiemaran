/*
    Proves dtc_sales_vs_spend neither drops nor duplicates what it reads.

    Over the last ~30 complete days:
      gross sales   the model's total must equal Shopify's own daily total;
      typed spend   the model's spend (Meta + Google + TikTok) must equal the spend
                    blended_performance holds for campaigns that have a spend_type.
    The spend side uses EXISTS rather than a join, deliberately: EXISTS cannot
    duplicate a row, so it is the independent answer the model's join is held to.

    The platform split and the type split are the same spend cut two ways, so a
    third check requires them to agree. They can only differ if a campaign has a
    platform but slipped out of the type pivot.

    The window ends the day before yesterday so a platform that syncs a few hours
    late cannot fail it, and starts no earlier than the model's first day.
*/

with win as (
    select
        greatest(
            convert_timezone('{{ var("time_zone", "US/Eastern") }}', getdate())::date - 31,
            (select min(date) from {{ ref('dtc_sales_vs_spend') }})
        ) as lo,
        convert_timezone('{{ var("time_zone", "US/Eastern") }}', getdate())::date - 2 as hi
),

m as (
    select
        coalesce(sum(p.gross_sales), 0) as gross_sales,
        coalesce(sum(coalesce(p.spend_meta, 0) + coalesce(p.spend_google, 0) + coalesce(p.spend_tiktok, 0)), 0) as spend_by_platform,
        coalesce(sum(coalesce(p.spend_prospecting, 0) + coalesce(p.spend_mixed, 0) + coalesce(p.spend_brand, 0) + coalesce(p.spend_nonbrand, 0)), 0) as spend_by_type
    from {{ ref('dtc_sales_vs_spend') }} p
    cross join win
    where p.date between win.lo and win.hi
),

shopify as (
    select coalesce(sum(s.gross_sales), 0) as gross_sales
    from {{ ref('shopify_sales_by_segment') }} s
    cross join win
    where s.date_granularity = 'day'
      and s.date between win.lo and win.hi
),

blended as (
    select coalesce(sum(b.spend), 0) as spend
    from {{ ref('blended_performance') }} b
    cross join win
    where b.date_granularity = 'day'
      and b.channel in ('Meta', 'Google', 'TikTok')
      and b.date between win.lo and win.hi
      and exists (
            select 1
            from ( {{ jm_budget_campaigns() }} ) k
            where k.platform    = lower(b.channel)
              and k.campaign_id = b.campaign_id
              and (k.segment_match = '' or k.segment_match = b.segment)
              and k.spend_type <> ''
      )
)

select 'gross_sales' as failed_check, m.gross_sales as model_value, shopify.gross_sales as source_value
from m cross join shopify
where abs(m.gross_sales - shopify.gross_sales) > 0.01

union all

select 'typed_spend', m.spend_by_platform, blended.spend
from m cross join blended
where abs(m.spend_by_platform - blended.spend) > 0.01

union all

select 'platform_vs_type_split', m.spend_by_platform, m.spend_by_type
from m
where abs(m.spend_by_platform - m.spend_by_type) > 0.01
