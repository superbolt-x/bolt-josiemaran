{#
    Josie Maran campaign names follow the Superbolt tag convention:

      plat:meta_br:jm_subchan:paidsocial-ASC_temp:evergreen_obj:website-and-shop-sales_cat:all-products_reg:us

    Every tag except the leading `plat:` is preceded by an underscore, so a tag's
    value is "the text between `_<tag>:` and the next underscore".

    Returns NULL when the tag is absent (legacy names such as
    "SB - DTC Prospecting Advantage+ - Evergreen - Purchase Campaign"), which the
    models bucket as 'Unclassified' rather than silently mis-attributing.

    Values are NOT lower-cased here — callers decide. Note the source data is
    case-inconsistent (`reg:us` and `reg:US` and `reg:CA` all occur), so any
    dimension built from a tag must lower() it first.
#}

{% macro parse_campaign_tag(column_name, tag) %}
    nullif(split_part(split_part({{ column_name }}, '_{{ tag }}:', 2), '_', 1), '')
{% endmacro %}
