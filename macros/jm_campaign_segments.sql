{#
════════════════════════════════════════════════════════════════════════════════
  Campaign ID → segment mapping
════════════════════════════════════════════════════════════════════════════════

  GENERATED from seeds/campaign_segments.csv by scripts/gen_segment_macro.py.
  Do not hand-edit. Edit the CSV and re-run the script.

  Segments are defined by CAMPAIGN ID, taken from the reporting deck — not
  parsed from campaign names. The account was inherited from the client and
  carries three incompatible naming conventions (tagged `plat:…`, new `SB - …`,
  legacy `BD - …`), with the same objective spelled `Traffic`, `traffic` and
  `Traffic-2`, and region as `us`/`US`/`ca`/`CA`/`USA`. Name parsing worked but
  it was inference; an ID list is the client's actual definition.

  Anything not in this list resolves to segment 'Unmapped'. That is deliberate
  and visible: unmapped spend shows on the Health rows rather than being
  silently folded into a total. When a campaign launches, add its ID here.

  Current mapping (18 campaigns, 8 segments):
      Google Overall       4 campaign(s): google:21704002557, google:21703908630, google:21703833786, google:24209915936
      Meta Overall         2 campaign(s): meta:120251956330760613, meta:120214146763940613
      Sephora @ Kohls      1 campaign(s): meta:120234201732920613
      Sephora CA Collab    2 campaign(s): meta:120239209497810303, meta:120250632750520303/adset:120250633537060303
      Sephora CA Traffic   3 campaign(s): meta:120250328578570303, tiktok:1874694608225890, tiktok:1836386473412625
      Sephora US Collab    2 campaign(s): meta:120219945963310303, meta:120250632750520303/adset:120250632750530303
      Sephora US Traffic   3 campaign(s): meta:120250319355050303, tiktok:1874691217255666, tiktok:1836369380956178
      TikTok Overall       1 campaign(s): tiktok:1876696959444129

  `Paid DTC Overall` is the rollup of every row with dtc_overall = true —
  the Meta Overall and Google Overall campaigns together.

  TikTok Overall is business_line DTC but dtc_overall = FALSE, deliberately.
  It is the GMV Max campaign, and its revenue is TikTok Shop GMV: those orders
  are placed in TikTok Shop, never reach Shopify, and never appear in GA4. So
  rolling it into `Paid DTC Overall` would put a second order system inside a
  number that otherwise means Shopify-attributed revenue, and would step the
  Paid DTC Overall trend line mid-quarter — the deck still prints that slide as
  "Meta & Google (& Eventually TikTok)". It reports on its own slide instead.
  Flipping this one cell to true is all that is needed when the client decides
  the rollup should include it.

  Emitted as UNION ALL rather than VALUES: Redshift rejects VALUES as a table
  constructor inside a CTE. Explicit casts on the first row stop it sizing each
  varchar from the first literal and truncating the rest.
#}

{% macro jm_campaign_segments() %}
        select 'google'::varchar(16)  as platform,
               '21704002557'::varchar(32) as campaign_id,
               ''::varchar(32) as adset_id,
               'Google Overall'::varchar(64) as segment,
               'DTC'::varchar(16)  as business_line,
               true::boolean       as dtc_overall
        union all select 'google', '21703908630', '', 'Google Overall', 'DTC', true
        union all select 'google', '21703833786', '', 'Google Overall', 'DTC', true
        union all select 'google', '24209915936', '', 'Google Overall', 'DTC', true
        union all select 'meta', '120251956330760613', '', 'Meta Overall', 'DTC', true
        union all select 'meta', '120214146763940613', '', 'Meta Overall', 'DTC', true
        union all select 'tiktok', '1876696959444129', '', 'TikTok Overall', 'DTC', false
        union all select 'meta', '120250319355050303', '', 'Sephora US Traffic', 'Sephora', false
        union all select 'tiktok', '1874691217255666', '', 'Sephora US Traffic', 'Sephora', false
        union all select 'tiktok', '1836369380956178', '', 'Sephora US Traffic', 'Sephora', false
        union all select 'meta', '120219945963310303', '', 'Sephora US Collab', 'Sephora', false
        union all select 'meta', '120250632750520303', '120250632750530303', 'Sephora US Collab', 'Sephora', false
        union all select 'meta', '120250328578570303', '', 'Sephora CA Traffic', 'Sephora', false
        union all select 'tiktok', '1874694608225890', '', 'Sephora CA Traffic', 'Sephora', false
        union all select 'tiktok', '1836386473412625', '', 'Sephora CA Traffic', 'Sephora', false
        union all select 'meta', '120239209497810303', '', 'Sephora CA Collab', 'Sephora', false
        union all select 'meta', '120250632750520303', '120250633537060303', 'Sephora CA Collab', 'Sephora', false
        union all select 'meta', '120234201732920613', '', 'Sephora @ Kohls', 'Sephora', false
{% endmacro %}


{#
  Market is read off the segment rather than a campaign tag — the segment names
  from the deck already encode it, and the tags do not agree with each other.
#}
{% macro jm_market_from_segment(segment) %}
    case
        when {{ segment }} like '%US%' then 'US'
        when {{ segment }} like '%CA%' then 'CA'
        -- Kohl's and the DTC rollups carry no region token in the segment
        -- name. Sephora at Kohl's is a US retailer, and 19,552 of 19,636
        -- Shopify orders (99.6%) ship to the US. TikTok Overall is the GMV Max
        -- campaign against the US TikTok Shop (store 7495649060905257667).
        when {{ segment }} in ('Meta Overall', 'Google Overall',
                              'TikTok Overall', 'Sephora @ Kohls')  then 'US'
        else 'Unknown'
    end
{% endmacro %}
