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

  Current mapping (15 campaigns, 7 segments):
      Google Overall       4 campaign(s): google:21704002557, google:21703908630, google:21703833786, google:24209915936
      Meta Overall         2 campaign(s): meta:120251956330760613, meta:120214146763940613
      Sephora @ Kohls      1 campaign(s): meta:120234201732920613
      Sephora CA Collab    1 campaign(s): meta:120239209497810303
      Sephora CA Traffic   3 campaign(s): meta:120250328578570303, tiktok:1874694608225890, tiktok:1836386473412625
      Sephora US Collab    1 campaign(s): meta:120219945963310303
      Sephora US Traffic   3 campaign(s): meta:120250319355050303, tiktok:1874691217255666, tiktok:1836369380956178

  `Paid DTC Overall` is the rollup of every row with dtc_overall = true —
  the Meta Overall and Google Overall campaigns together.
#}

{% macro jm_campaign_segments() %}
    select * from (
        values
        ('google', '21704002557', 'Google Overall', 'DTC', true),
        ('google', '21703908630', 'Google Overall', 'DTC', true),
        ('google', '21703833786', 'Google Overall', 'DTC', true),
        ('google', '24209915936', 'Google Overall', 'DTC', true),
        ('meta', '120251956330760613', 'Meta Overall', 'DTC', true),
        ('meta', '120214146763940613', 'Meta Overall', 'DTC', true),
        ('meta', '120250319355050303', 'Sephora US Traffic', 'Sephora', false),
        ('tiktok', '1874691217255666', 'Sephora US Traffic', 'Sephora', false),
        ('tiktok', '1836369380956178', 'Sephora US Traffic', 'Sephora', false),
        ('meta', '120219945963310303', 'Sephora US Collab', 'Sephora', false),
        ('meta', '120250328578570303', 'Sephora CA Traffic', 'Sephora', false),
        ('tiktok', '1874694608225890', 'Sephora CA Traffic', 'Sephora', false),
        ('tiktok', '1836386473412625', 'Sephora CA Traffic', 'Sephora', false),
        ('meta', '120239209497810303', 'Sephora CA Collab', 'Sephora', false),
        ('meta', '120234201732920613', 'Sephora @ Kohls', 'Sephora', false)
    ) as t(platform, campaign_id, segment, business_line, dtc_overall)
{% endmacro %}


{#
  Market is read off the segment rather than a campaign tag — the segment names
  from the deck already encode it, and the tags do not agree with each other.
#}
{% macro jm_market_from_segment(segment) %}
    case
        when {{ segment }} like '%US%' then 'US'
        when {{ segment }} like '%CA%' then 'CA'
        when {{ segment }} in ('Meta Overall', 'Google Overall') then 'US'
        else 'Unknown'
    end
{% endmacro %}
