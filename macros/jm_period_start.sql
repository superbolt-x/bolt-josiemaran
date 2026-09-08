{#
════════════════════════════════════════════════════════════════════════════════
  Period truncation that matches the packages
════════════════════════════════════════════════════════════════════════════════

  ⚠ WEEKS ARE SUNDAY-ANCHORED. Redshift's `date_trunc('week', d)` returns the
  ISO Monday, but every packaged reporting table anchors its weekly rows on
  Sunday — verified across facebook, googleads, tiktok and shopify_sales, which
  all carry 2026-08-16 / 08-23 / 08-30 / 09-06.

  Any model that derives its own weeks with a bare date_trunc therefore lands
  one day off, and the blended table ends up with TWO sets of week dates: the
  packages' Sundays and our Mondays. Nothing errors — the rows just fail to
  roll up together and every weekly number silently halves.

  So: use this macro, never a bare date_trunc, anywhere a week is derived.

  Month / quarter / year are anchor-independent and pass straight through.

  If the packages ever switch to Monday (dbt_project.yml has
  `week_start: 'Monday'`, which is NOT what the built tables reflect), change
  the week branch here and nothing else.
#}

{% macro jm_period_start(date_col, granularity_col) %}
    case {{ granularity_col }}
        when 'day'     then {{ date_col }}
        when 'week'    then (date_trunc('week', {{ date_col }} + 1) - 1)::date
        when 'month'   then date_trunc('month',   {{ date_col }})::date
        when 'quarter' then date_trunc('quarter', {{ date_col }})::date
        when 'year'    then date_trunc('year',    {{ date_col }})::date
    end
{% endmacro %}


{# Single-granularity form, for CTEs that only need weeks. #}
{% macro jm_week_start(date_col) %}
    (date_trunc('week', {{ date_col }} + 1) - 1)::date
{% endmacro %}
