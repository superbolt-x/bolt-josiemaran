{#
════════════════════════════════════════════════════════════════════════════════
  Reporting dimensions — single source of truth
════════════════════════════════════════════════════════════════════════════════

  Defined once here so the taxonomy cannot drift between models the way
  hard-coded channel lists drift between Metabase cards.

  ── THREE NAMING CONVENTIONS MUST ALL WORK ──────────────────────────────────
  Tagged (pre-takeover):
      plat:meta_br:jm_subchan:paidsocial-prospecting_temp:sephora_obj:Purchase_cat:all-products_reg:us
  `SB - ` (post-takeover, 2026-09-01 onward, NO TAGS):
      SB - US - Sephora Prospecting - Evergreen - Traffic - Clicks
      SB - CA - Sephora Prospecting - Evergreen - Traffic - Clicks
      SB - DTC Prospecting Advantage+ - Evergreen - Purchase Campaign

  `BD - ` / `[JM] BD - ` / `[S] BD - ` (pre-Superbolt, 2023-07 → 2026-08):
      [S] BD - USA - Sephora Support - Traffic
      BD - ASC+ - DPA
      [JM] BD - Retargeting - DPA - V2

  A tag-only parser would bucket every new campaign as 'Unclassified' — the two
  new `SB - ` Sephora traffic campaigns carry ~92% of live Sephora spend, and
  the `BD - ` era holds $1.44M of history that any YoY comparison needs. Note
  `USA` in the legacy convention vs `us`/`US` in the tags. Every macro below
  handles all three forms.

  ── business_line ───────────────────────────────────────────────────────────
  The two P&Ls in the 2026 plan: $57.2M Sephora, $17.2M JM.com, $75M total.

    'Sephora'  drives sephora.com / Sephora at Kohl's. Converts on SEPHORA's
               pixel, so it produces NO Shopify revenue and NO rows in Meta's
               own `purchases` column. Measured on catalog segment actions.
    'DTC'      drives josiemaran.com. Measured on Shopify + Meta/Google.

  Deliberately NOT the ad account: $144k of `temp:sephora-KOHLS` retail spend
  sits inside the DTC Meta account (594708350991342).
#}

{% macro jm_business_line(campaign_name) %}
    case
        when {{ campaign_name }} is null                                then 'Unclassified'
        when lower({{ campaign_name }}) like '%sephora%'                then 'Sephora'
        when lower({{ campaign_name }}) like '%kohls%'                  then 'Sephora'
        else 'DTC'
    end
{% endmacro %}


{#
  ── meta_segment ───────────────────────────────────────────────────────────
  The reporting rows the Sephora side is actually managed on: US Traffic,
  US Collab, CA Traffic, CA Collab. Traffic and Collab behave nothing alike and
  are measured differently, so they must never be summed into one "Meta Sephora"
  line. Measured over full history:

      US Traffic  $823,027 spend →   1,551 cs purchases → 0.07 ROAS
      US Collab    $72,388 spend →   2,034 cs purchases → 1.14 ROAS
      CA Traffic  $158,501 spend →     276 cs purchases → 0.06 ROAS
      CA Collab    $12,618 spend →     895 cs purchases → 2.93 ROAS

  Collab (purchase-optimised, using Sephora's catalog/DPA) returns 16-49x the
  ROAS of Traffic on a fraction of the budget. The retired ATC and Engagement
  campaigns are kept as their own segments rather than folded away, so the
  before/after of the August restructure stays readable.
#}

{% macro jm_meta_segment(campaign_name) %}
    case
        when {{ campaign_name }} is null then 'Unclassified'

        -- Sephora at Kohl's — retail, but a distinct partner and calendar
        when lower({{ campaign_name }}) like '%kohls%'                  then 'Kohls Traffic'

        -- New `SB - ` convention (no tags)
        when {{ campaign_name }} like 'SB - US - Sephora%Traffic%'      then 'US Traffic'
        when {{ campaign_name }} like 'SB - CA - Sephora%Traffic%'      then 'CA Traffic'
        when {{ campaign_name }} like 'SB - DTC%Purchase%'              then 'DTC Prospecting'

        -- Legacy `BD - ` convention, Sephora side. These are the same two
        -- segments as today's traffic campaigns, so they map to the same labels
        -- and the trend stays continuous across the August restructure.
        when {{ campaign_name }} like '[S] BD - USA - Sephora%'         then 'US Traffic'
        when {{ campaign_name }} like '[S] BD - CA - Sephora%'          then 'CA Traffic'

        -- Tagged convention: Sephora side
        when lower({{ campaign_name }}) like '%sephora%' then
            case
                when lower({{ parse_campaign_tag(campaign_name, 'obj') }}) like 'traffic%'
                     then upper(coalesce({{ parse_campaign_tag(campaign_name, 'reg') }}, 'XX')) || ' Traffic'
                when lower({{ parse_campaign_tag(campaign_name, 'obj') }}) = 'purchase'
                     then upper(coalesce({{ parse_campaign_tag(campaign_name, 'reg') }}, 'XX')) || ' Collab'
                when lower({{ parse_campaign_tag(campaign_name, 'obj') }}) = 'add-to-cart'
                     then upper(coalesce({{ parse_campaign_tag(campaign_name, 'reg') }}, 'XX')) || ' ATC'
                when lower({{ parse_campaign_tag(campaign_name, 'obj') }}) = 'engagement'
                     then upper(coalesce({{ parse_campaign_tag(campaign_name, 'reg') }}, 'XX')) || ' Engagement'
                else 'Sephora Other'
            end

        -- Legacy `BD - ` convention, DTC side
        when {{ campaign_name }} like '%BD - %' then
            case
                when lower({{ campaign_name }}) like '%asc+%'         then 'DTC ASC'
                when lower({{ campaign_name }}) like '%retargeting%'  then 'DTC Retargeting'
                when lower({{ campaign_name }}) like '%lifecycle%'    then 'DTC Lifecycle'
                when lower({{ campaign_name }}) like '%- lc%'         then 'DTC Lifecycle'
                when lower({{ campaign_name }}) like '%traffic%'      then 'DTC Traffic'
                when lower({{ campaign_name }}) like '%prospecting%'  then 'DTC Prospecting'
                else 'DTC Other'
            end

        -- Tagged convention: DTC side
        when lower({{ parse_campaign_tag(campaign_name, 'subchan') }}) like '%asc%'        then 'DTC ASC'
        when lower({{ parse_campaign_tag(campaign_name, 'subchan') }}) like '%lifecycle%'  then 'DTC Lifecycle'
        when lower({{ parse_campaign_tag(campaign_name, 'obj') }}) in ('sales','website-and-shop-sales','purchase')
                                                                                            then 'DTC Prospecting'
        when lower({{ parse_campaign_tag(campaign_name, 'obj') }}) = 'traffic'              then 'DTC Traffic'
        when lower({{ parse_campaign_tag(campaign_name, 'obj') }}) = 'leads'                then 'DTC Leads'
        else 'DTC Other'
    end
{% endmacro %}


{% macro jm_funnel(campaign_name) %}
    case
        when {{ campaign_name }} is null then 'Unclassified'
        when {{ campaign_name }} like 'SB - %Traffic%'   then 'Upper'
        when {{ campaign_name }} like 'SB - %Purchase%'  then 'Lower'
        when {{ campaign_name }} like '%BD - %' then
            case
                when lower({{ campaign_name }}) like '%traffic%'  then 'Upper'
                when lower({{ campaign_name }}) like '%tof%'      then 'Upper'
                else 'Lower'
            end
        else
            case lower({{ parse_campaign_tag(campaign_name, 'obj') }})
                when 'sales'                  then 'Lower'
                when 'website-and-shop-sales' then 'Lower'
                when 'conversion'             then 'Lower'
                when 'purchase'               then 'Lower'
                when 'add-to-cart'            then 'Mid'
                when 'leads'                  then 'Mid'
                when 'traffic'                then 'Upper'
                when 'reach'                  then 'Upper'
                when 'engagement'             then 'Upper'
                when 'followers'              then 'Upper'
                else 'Unclassified'
            end
    end
{% endmacro %}


{#
  ── market ─────────────────────────────────────────────────────────────────
  Source tags are case-inconsistent (`reg:us`, `reg:US`, `reg:CA`, `reg:ca`),
  so everything is lower()ed before comparison.

  ASSUMPTION, worth a decision: an untagged DTC campaign is treated as US.
  `SB - DTC Prospecting Advantage+ …` carries no region and is the main live DTC
  purchase campaign, and 19,552 of 19,636 Shopify orders (99.6%) ship to the US.
  The data-health card reports any spend still landing in 'Unknown'.
#}

{% macro jm_market(campaign_name) %}
    case
        when {{ campaign_name }} is null                          then 'Unknown'
        when {{ campaign_name }} like 'SB - US - %'               then 'US'
        when {{ campaign_name }} like 'SB - CA - %'               then 'CA'
        when {{ campaign_name }} like '%- USA -%'                 then 'US'
        when {{ campaign_name }} like '%- CA -%'                  then 'CA'
        when lower({{ parse_campaign_tag(campaign_name, 'reg') }}) = 'us'  then 'US'
        when lower({{ parse_campaign_tag(campaign_name, 'reg') }}) = 'ca'  then 'CA'
        when {{ parse_campaign_tag(campaign_name, 'reg') }} is not null
             then upper({{ parse_campaign_tag(campaign_name, 'reg') }})
        when lower({{ campaign_name }}) like '%sephora%'
          or lower({{ campaign_name }}) like '%kohls%'             then 'Unknown'
        else 'US'   -- untagged DTC; see note above
    end
{% endmacro %}


{# Shopify ships to a country code, not a campaign tag — same output vocabulary. #}
{% macro jm_market_from_country(country_code) %}
    case upper(coalesce({{ country_code }}, ''))
        when 'US' then 'US'
        when 'CA' then 'CA'
        when ''   then 'Unknown'
        else 'Other'
    end
{% endmacro %}
