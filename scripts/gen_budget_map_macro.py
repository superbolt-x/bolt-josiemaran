#!/usr/bin/env python3
"""
Regenerate macros/jm_budget_campaigns.sql from seeds/budget_campaign_map.csv.

    python3 scripts/gen_budget_map_macro.py

What this mapping is for
  budget_pacing joins the client's daily BUDGET rows (gsheet_raw, keyed by
  business_unit / platform / campaign_key) to ACTUAL spend (blended_performance,
  keyed by campaign_id). This file is the bridge, and it also carries what the
  Gsheet needs to draw a series: legend label, stack order, and two colours (one
  for forecast days, one for actual days).

Why it is NOT campaign_segments.csv
  Segments are the client's REPORTING definition. Adding Lead Gen there would
  move $838 of September spend into "Meta Overall" and "Paid DTC Overall" and
  change numbers the client already received. Budget keys are a different
  question (which line of the budget sheet is this campaign?), so they live in
  their own file and cannot change an existing report.

Why a generated macro and not a dbt seed
  Same reason as gen_segment_macro.py: the mapping must work in the standalone
  (pre-dbt) Metabase card, and a seed needs `dbt seed` to have run first.

Edit the CSV, run this, then re-run scripts/build_sheet_cards.py.
"""
import csv, pathlib, re, sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SRC  = ROOT / "seeds" / "budget_campaign_map.csv"
DEST = ROOT / "macros" / "jm_budget_campaigns.sql"

PLATFORMS = {"meta", "google", "tiktok"}
UNITS = ["dtc", "sephora_us", "sephora_ca", "sephora_kohls"]
COLUMNS = ["platform", "campaign_id", "segment_match", "business_unit",
           "campaign_key", "legend_label", "stack_order", "forecast_color",
           "actual_color", "spend_type"]
# How the DTC Shopify charts classify a budget line ("Spend by type vs. new
# customers"). Blank means the line is not part of that comparison: TikTok GMV Max
# is blank because its revenue is TikTok Shop GMV, which never reaches Shopify.
SPEND_TYPES = {"prospecting", "mixed", "brand", "nonbrand"}
HEX = re.compile(r"^#[0-9A-Fa-f]{6}$")
KEY = re.compile(r"^[a-z0-9_]+$")

rows = list(csv.DictReader(SRC.open()))
if not rows:
    sys.exit("budget_campaign_map.csv is empty")
missing = [c for c in COLUMNS if c not in rows[0]]
if missing:
    sys.exit(f"budget_campaign_map.csv is missing columns: {missing}")

for r in rows:
    for k in r:
        r[k] = (r[k] or "").strip()

seen, grain_of, attrs_of, order_of = {}, {}, {}, {}

for i, r in enumerate(rows, 2):
    if r["platform"] not in PLATFORMS:
        sys.exit(f"line {i}: platform must be one of {sorted(PLATFORMS)}")
    if r["business_unit"] not in UNITS:
        sys.exit(f"line {i}: business_unit must be one of {UNITS}")
    if not KEY.match(r["campaign_key"]):
        sys.exit(f"line {i}: campaign_key must be lowercase snake_case")
    # A blank campaign_id is allowed: it declares a budget line that has no
    # live campaign yet (e.g. TikTok Web before it launches), so the Gsheet can
    # already draw its series. It simply never matches any spend.
    if r["campaign_id"] and not r["campaign_id"].isdigit():
        sys.exit(f"line {i}: campaign_id must be numeric or blank")
    if r["segment_match"] and not r["campaign_id"]:
        sys.exit(f"line {i}: segment_match needs a campaign_id")
    if not r["stack_order"].isdigit() or int(r["stack_order"]) < 1:
        sys.exit(f"line {i}: stack_order must be a positive integer")
    for col in ("forecast_color", "actual_color"):
        if not HEX.match(r[col]):
            sys.exit(f"line {i}: {col} must look like #A4C2F4")
    if not r["legend_label"]:
        sys.exit(f"line {i}: legend_label is required")
    if r["spend_type"] and r["spend_type"] not in SPEND_TYPES:
        sys.exit(f"line {i}: spend_type must be blank or one of {sorted(SPEND_TYPES)}")
    if r["spend_type"] and r["business_unit"] != "dtc":
        sys.exit(f"line {i}: spend_type only applies to business_unit dtc "
                 f"(the Shopify comparison is a DTC concept)")

    if r["campaign_id"]:
        k = (r["platform"], r["campaign_id"], r["segment_match"])
        if k in seen:
            sys.exit(f"line {i}: duplicate mapping {k} (already on line {seen[k]})")
        seen[k] = i

        # A campaign maps EITHER as a whole (blank segment_match) OR segment by
        # segment, never both. With both present one spend row would match two
        # mapping rows in budget_pacing's join and double-count. Stating the
        # rule here, at edit time, is what lets the SQL join stay a plain
        # equality with no precedence logic -- same invariant, same reason, as
        # gen_segment_macro.py's whole-vs-adset rule.
        grain = "segment" if r["segment_match"] else "campaign"
        ck = (r["platform"], r["campaign_id"])
        if ck in grain_of and grain_of[ck][0] != grain:
            sys.exit(f"line {i}: campaign {ck[1]} is mapped at {grain} level here "
                     f"but at {grain_of[ck][0]} level on line {grain_of[ck][1]}. "
                     f"A campaign maps either as a whole or per segment, never both.")
        grain_of.setdefault(ck, (grain, i))

    # Rows that share a budget line must agree on how it is drawn and classified,
    # otherwise the Gsheet would pick whichever row it read first.
    key = (r["business_unit"], r["platform"], r["campaign_key"])
    attrs = (r["legend_label"], r["stack_order"], r["forecast_color"].upper(),
             r["actual_color"].upper(), r["spend_type"])
    if key in attrs_of and attrs_of[key][0] != attrs:
        sys.exit(f"line {i}: {key} has different label/order/colours/spend_type than on "
                 f"line {attrs_of[key][1]}. Rows sharing a campaign_key must match.")
    attrs_of.setdefault(key, (attrs, i))

    # stack_order fixes the stacking order of the series, so two budget lines in
    # the same chart cannot share one.
    ok = (r["business_unit"], r["stack_order"])
    if ok in order_of and order_of[ok][0] != key:
        sys.exit(f"line {i}: stack_order {r['stack_order']} in {r['business_unit']} "
                 f"is already used by {order_of[ok][0]} (line {order_of[ok][1]}).")
    order_of.setdefault(ok, (key, i))


def q(s):
    return s.replace("'", "''")


# ── jm_budget_campaigns(): campaign -> budget line, spend-matching rows only ──
# Redshift rejects VALUES as a table constructor inside a CTE/subquery, so this
# is a UNION ALL; the first row carries explicit casts so Redshift does not size
# each varchar from the first literal and truncate the longer rows. segment_match
# is '' (not NULL) for a whole-campaign row: `is null` in a join predicate over a
# UNION ALL of literals makes Redshift's planner fail with a bare "Assert".
match_rows = [r for r in rows if r["campaign_id"]]
lines = []
for i, r in enumerate(match_rows):
    seg = f"'{q(r['segment_match'])}'" if r["segment_match"] else "''"
    if i == 0:
        lines.append(
            f"        select '{r['platform']}'::varchar(16)  as platform,\n"
            f"               '{r['campaign_id']}'::varchar(32) as campaign_id,\n"
            f"               {seg}::varchar(64) as segment_match,\n"
            f"               '{r['business_unit']}'::varchar(32) as business_unit,\n"
            f"               '{r['campaign_key']}'::varchar(64) as campaign_key,\n"
            f"               '{r['spend_type']}'::varchar(16) as spend_type")
    else:
        lines.append(
            f"        union all select '{r['platform']}', '{r['campaign_id']}', {seg}, "
            f"'{r['business_unit']}', '{r['campaign_key']}', '{r['spend_type']}'")
campaigns_sql = "\n".join(lines)

# ── jm_budget_keys(): one row per budget line, with how to draw it ───────────
key_rows = sorted(attrs_of.items(),
                  key=lambda kv: (UNITS.index(kv[0][0]), int(kv[1][0][1]), kv[0][1]))
klines = []
for i, ((bu, plat, ck), ((label, order, fc, ac, st), _)) in enumerate(key_rows):
    if i == 0:
        klines.append(
            f"        select '{bu}'::varchar(32) as business_unit,\n"
            f"               '{plat}'::varchar(16) as platform,\n"
            f"               '{ck}'::varchar(64) as campaign_key,\n"
            f"               '{q(label)}'::varchar(64) as legend_label,\n"
            f"               {int(order)}::integer as stack_order,\n"
            f"               '{fc}'::varchar(7) as forecast_color,\n"
            f"               '{ac}'::varchar(7) as actual_color,\n"
            f"               '{st}'::varchar(16) as spend_type")
    else:
        klines.append(
            f"        union all select '{bu}', '{plat}', '{ck}', '{q(label)}', "
            f"{int(order)}, '{fc}', '{ac}', '{st}'")
keys_sql = "\n".join(klines)

summary = "\n".join(
    f"      {bu:<14} {n} budget line(s), {sum(1 for r in match_rows if r['business_unit'] == bu)} campaign id(s)"
    for bu, n in ((u, sum(1 for k in attrs_of if k[0] == u)) for u in UNITS))

DEST.write_text(f"""{{#
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

  Current mapping ({len(match_rows)} campaign ids, {len(attrs_of)} budget lines):
{summary}

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

  Both carry spend_type (prospecting / mixed / brand / nonbrand, or '' for a
  line outside the DTC Shopify comparison, e.g. GMV Max). It is how the "Spend by
  type vs. new customers" chart classifies spend, kept here so a campaign is
  classified in the one place it is already mapped.

  Inline each macro at its use site rather than sharing a CTE -- see the note in
  blended_performance.sql on the Redshift planner "Assert".
#}}

{{% macro jm_budget_campaigns() %}}
{campaigns_sql}
{{% endmacro %}}


{{% macro jm_budget_keys() %}}
{keys_sql}
{{% endmacro %}}
""")
print(f"wrote {DEST.relative_to(ROOT)} -- {len(match_rows)} campaign ids, {len(attrs_of)} budget lines")
for bu in UNITS:
    print(f"  {bu:<14} " + ", ".join(f"{k[1]}/{k[2]}" for k in sorted(
        (k for k in attrs_of if k[0] == bu), key=lambda k: int(attrs_of[k][0][1]))))
