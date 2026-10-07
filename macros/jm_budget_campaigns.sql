{#
════════════════════════════════════════════════════════════════════════════════
  Campaign ID -> budget line, plus how each budget line is drawn
════════════════════════════════════════════════════════════════════════════════

  GENERATED from seeds/budget_campaign_map.csv by scripts/gen_budget_map_macro.py.
  Do not hand-edit. Edit the CSV and re-run the script.

  A "budget line" is one row of the client's daily budget sheet, identified by
  (business_unit, platform, campaign_key) -- the same three columns the loader
  budget_forecast_to_redshift.py writes to gsheet_raw.josie_maran_budget_forecast.

  This is deliberately NOT campaign_segments.csv. Segments are the client's
  reporting definition; budget lines are a different question, and mapping Lead
  Gen into a segment would change numbers the client has already received.

  Current mapping (19 campaign ids, 18 budget lines):
      dtc            9 budget line(s), 8 campaign id(s)
      sephora_us     4 budget line(s), 5 campaign id(s)
      sephora_ca     4 budget line(s), 5 campaign id(s)
      sephora_kohls  1 budget line(s), 1 campaign id(s)

  Two macros:
    jm_budget_campaigns()  one row per campaign id (or per segment of a split
                           campaign) -> the budget line its spend belongs to.
                           segment_match = '' means the whole campaign; a value
                           means only rows whose blended_performance segment
                           equals it (campaign 120250632750520303 holds a US and
                           a CA adset that are different budget lines).
    jm_budget_keys()       one row per budget line, with legend_label,
                           stack_order, and the two colours the Gsheet draws it
                           in (forecast days, actual days). A line with no
                           campaign id yet (TikTok Web before launch) is here
                           but not in jm_budget_campaigns().

  Inline each macro at its use site rather than sharing a CTE -- see the note in
  blended_performance.sql on the Redshift planner "Assert".
#}

{% macro jm_budget_campaigns() %}
        select 'meta'::varchar(16)  as platform,
               '120251956330760613'::varchar(32) as campaign_id,
               ''::varchar(64) as segment_match,
               'dtc'::varchar(32) as business_unit,
               'prospecting_advplus'::varchar(64) as campaign_key
        union all select 'meta', '120214146763940613', '', 'dtc', 'temp_retargeting'
        union all select 'meta', '120252630357450613', '', 'dtc', 'lead_gen'
        union all select 'google', '21703833786', '', 'dtc', 'us_branded_pmax'
        union all select 'google', '21704002557', '', 'dtc', 'us_branded_search'
        union all select 'google', '21703908630', '', 'dtc', 'ca_branded_search'
        union all select 'google', '24209915936', '', 'dtc', 'nb_pmax'
        union all select 'tiktok', '1876696959444129', '', 'dtc', 'gmv_max'
        union all select 'meta', '120250319355050303', '', 'sephora_us', 'us_traffic'
        union all select 'meta', '120219945963310303', '', 'sephora_us', 'us_collab'
        union all select 'meta', '120250632750520303', 'Sephora US Collab', 'sephora_us', 'new_us_collab'
        union all select 'tiktok', '1874691217255666', '', 'sephora_us', 'us_traffic'
        union all select 'tiktok', '1836369380956178', '', 'sephora_us', 'us_traffic'
        union all select 'meta', '120250328578570303', '', 'sephora_ca', 'ca_traffic'
        union all select 'meta', '120239209497810303', '', 'sephora_ca', 'ca_collab'
        union all select 'meta', '120250632750520303', 'Sephora CA Collab', 'sephora_ca', 'new_ca_collab'
        union all select 'tiktok', '1874694608225890', '', 'sephora_ca', 'ca_traffic'
        union all select 'tiktok', '1836386473412625', '', 'sephora_ca', 'ca_traffic'
        union all select 'meta', '120234201732920613', '', 'sephora_kohls', 'kohls_us_traffic'
{% endmacro %}


{% macro jm_budget_keys() %}
        select 'dtc'::varchar(32) as business_unit,
               'meta'::varchar(16) as platform,
               'prospecting_advplus'::varchar(64) as campaign_key,
               'Meta Prospecting Adv+'::varchar(64) as legend_label,
               1::integer as stack_order,
               '#A4C2F4'::varchar(7) as forecast_color,
               '#D9D9D9'::varchar(7) as actual_color
        union all select 'dtc', 'meta', 'temp_retargeting', 'Meta Retargeting (OG ASC)', 2, '#3C78D8', '#CCCCCC'
        union all select 'dtc', 'meta', 'lead_gen', 'Lead Gen', 3, '#2343AA', '#B7B7B7'
        union all select 'dtc', 'google', 'us_branded_pmax', 'Google US PMax Branded', 4, '#38761D', '#666666'
        union all select 'dtc', 'google', 'us_branded_search', 'Google US Branded Search', 5, '#6AA84F', '#999999'
        union all select 'dtc', 'google', 'ca_branded_search', 'Google CA Branded Search', 6, '#93C47D', '#B7B7B7'
        union all select 'dtc', 'google', 'nb_pmax', 'Google NB PMax', 7, '#B6D7A8', '#CCCCCC'
        union all select 'dtc', 'tiktok', 'gmv_max', 'TikTok GMV Max', 8, '#E69138', '#434343'
        union all select 'dtc', 'tiktok', 'prospecting_web', 'TikTok Web', 9, '#F9CB9C', '#999999'
        union all select 'sephora_us', 'meta', 'us_traffic', 'Meta US Traffic', 1, '#A4C2F4', '#B7B7B7'
        union all select 'sephora_us', 'meta', 'us_collab', 'Meta US Collab', 2, '#3C78D8', '#999999'
        union all select 'sephora_us', 'meta', 'new_us_collab', 'New US Collab', 3, '#2343AA', '#666666'
        union all select 'sephora_us', 'tiktok', 'us_traffic', 'TikTok US Traffic', 4, '#FF9900', '#434343'
        union all select 'sephora_ca', 'meta', 'ca_traffic', 'Meta CA Traffic', 1, '#A4C2F4', '#B7B7B7'
        union all select 'sephora_ca', 'meta', 'ca_collab', 'Meta CA Collab', 2, '#3C78D8', '#999999'
        union all select 'sephora_ca', 'meta', 'new_ca_collab', 'New CA Collab', 3, '#2343AA', '#666666'
        union all select 'sephora_ca', 'tiktok', 'ca_traffic', 'TikTok CA Traffic', 4, '#FF9900', '#434343'
        union all select 'sephora_kohls', 'meta', 'kohls_us_traffic', 'Meta Traffic', 1, '#A4C2F4', '#999999'
{% endmacro %}
