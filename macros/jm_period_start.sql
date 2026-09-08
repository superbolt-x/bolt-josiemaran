{#
════════════════════════════════════════════════════════════════════════════════
  Period truncation, anchored to var('week_start')
════════════════════════════════════════════════════════════════════════════════

  `dbt_project.yml` sets `week_start: 'Sunday'` — the client asked for Sunday
  weeks and the packages honour it, so every packaged reporting table anchors
  its weekly rows on Sunday (facebook, googleads, tiktok and shopify_sales all
  carry 2026-08-16 / 08-23 / 08-30 / 09-06).

  Redshift's `date_trunc('week', d)` returns the ISO **Monday**. So a model that
  derives its own weeks with a bare date_trunc lands one day off, and the
  blended table ends up with two sets of week dates — the packages' Sundays and
  ours. Nothing errors; the rows just fail to roll up together and every weekly
  number silently halves.

  This macro reads the same var the packages do, so the two cannot disagree.
  Flip `week_start` in dbt_project.yml and both move together.

  ── WHERE THIS IS AND ISN'T NEEDED ──────────────────────────────────────────
  Only for the three sources that arrive DAILY with no date_granularity of
  their own — order-level Shopify, the Facebook catalog-segment EAV tables, and
  GA4 sessions. Anything already carrying `date_granularity` (i.e. every
  packaged reporting table, and blended_performance itself) must be read by
  FILTERING that column, never by re-truncating `date`.

  Month / quarter / year are anchor-independent and pass straight through.
#}

{% macro jm_period_start(date_col, granularity_col) %}
    case {{ granularity_col }}
        when 'day'     then {{ date_col }}
        when 'week'    then {{ jm_week_start(date_col) }}
        when 'month'   then date_trunc('month',   {{ date_col }})::date
        when 'quarter' then date_trunc('quarter', {{ date_col }})::date
        when 'year'    then date_trunc('year',    {{ date_col }})::date
    end
{% endmacro %}


{% macro jm_week_start(date_col) %}
    {%- set ws = var('week_start', 'Monday') | lower -%}
    {%- if ws.startswith('sun') -%}
    (date_trunc('week', {{ date_col }} + 1) - 1)::date
    {%- else -%}
    date_trunc('week', {{ date_col }})::date
    {%- endif -%}
{% endmacro %}
