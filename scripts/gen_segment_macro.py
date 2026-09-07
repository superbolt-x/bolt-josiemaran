#!/usr/bin/env python3
"""
Regenerate macros/jm_campaign_segments.sql from seeds/campaign_segments.csv.

    python3 scripts/gen_segment_macro.py

Why a generated macro and not a dbt seed: the mapping has to be available to the
standalone (pre-dbt) Metabase card too, and a seed would need `dbt seed` to have
run first. Emitting an inline VALUES list means the CSV stays the human-editable
source of truth while the SQL works everywhere with no extra build step.

Edit the CSV, run this, then re-run scripts/build_standalone_feed.py.
"""
import csv, pathlib, sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SRC  = ROOT / "seeds" / "campaign_segments.csv"
DEST = ROOT / "macros" / "jm_campaign_segments.sql"

VALID_BL  = {"DTC", "Sephora"}
VALID_BOOL = {"true", "false"}

rows = list(csv.DictReader(SRC.open()))
if not rows:
    sys.exit("campaign_segments.csv is empty")

seen = {}
for i, r in enumerate(rows, 2):
    key = (r["platform"].strip(), r["campaign_id"].strip())
    if key in seen:
        sys.exit(f"line {i}: duplicate {key} (already on line {seen[key]})")
    seen[key] = i
    if r["business_line"].strip() not in VALID_BL:
        sys.exit(f"line {i}: business_line must be one of {sorted(VALID_BL)}")
    if r["dtc_overall"].strip().lower() not in VALID_BOOL:
        sys.exit(f"line {i}: dtc_overall must be true/false")
    if not r["campaign_id"].strip().isdigit():
        sys.exit(f"line {i}: campaign_id must be numeric")
    if r["dtc_overall"].strip().lower() == "true" and r["business_line"].strip() != "DTC":
        sys.exit(f"line {i}: dtc_overall=true requires business_line=DTC")

segments = sorted({r["segment"].strip() for r in rows})
by_seg = {}
for r in rows:
    by_seg.setdefault(r["segment"].strip(), []).append(r)

# Redshift does NOT support VALUES as a table constructor inside a subquery or
# CTE — only in INSERT ... VALUES. So the mapping is emitted as a UNION ALL of
# SELECTs. The first row carries explicit casts: without them Redshift sizes
# each varchar from the first literal it sees and silently truncates the longer
# rows ('Google Overall' is 14 chars, 'Sephora US Traffic' is 18).
_lines = []
for i, r in enumerate(rows):
    p_, cid = r["platform"].strip(), r["campaign_id"].strip()
    seg = r["segment"].strip().replace("'", "''")
    bl, dtc = r["business_line"].strip(), r["dtc_overall"].strip().lower()
    if i == 0:
        _lines.append(
            f"        select '{p_}'::varchar(16)  as platform,\n"
            f"               '{cid}'::varchar(32) as campaign_id,\n"
            f"               '{seg}'::varchar(64) as segment,\n"
            f"               '{bl}'::varchar(16)  as business_line,\n"
            f"               {dtc}::boolean       as dtc_overall"
        )
    else:
        _lines.append(f"        union all select '{p_}', '{cid}', '{seg}', '{bl}', {dtc}")
values = "\n".join(_lines)

summary = "\n".join(
    f"      {seg:<20} {len(v)} campaign(s): "
    + ", ".join(f"{x['platform']}:{x['campaign_id']}" for x in v)
    for seg, v in sorted(by_seg.items())
)

DEST.write_text(f"""{{#
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

  Current mapping ({len(rows)} campaigns, {len(segments)} segments):
{summary}

  `Paid DTC Overall` is the rollup of every row with dtc_overall = true —
  the Meta Overall and Google Overall campaigns together.

  Emitted as UNION ALL rather than VALUES: Redshift rejects VALUES as a table
  constructor inside a CTE. Explicit casts on the first row stop it sizing each
  varchar from the first literal and truncating the rest.
#}}

{{% macro jm_campaign_segments() %}}
{values}
{{% endmacro %}}


{{#
  Market is read off the segment rather than a campaign tag — the segment names
  from the deck already encode it, and the tags do not agree with each other.
#}}
{{% macro jm_market_from_segment(segment) %}}
    case
        when {{{{ segment }}}} like '%US%' then 'US'
        when {{{{ segment }}}} like '%CA%' then 'CA'
        -- Kohl's and the two DTC rollups carry no region token in the segment
        -- name. Sephora at Kohl's is a US retailer, and 19,552 of 19,636
        -- Shopify orders (99.6%) ship to the US.
        when {{{{ segment }}}} in ('Meta Overall', 'Google Overall',
                              'Sephora @ Kohls')                then 'US'
        else 'Unknown'
    end
{{% endmacro %}}
""")
print(f"wrote {DEST.relative_to(ROOT)} — {len(rows)} campaigns, {len(segments)} segments")
for seg, v in sorted(by_seg.items()):
    print(f"  {seg:<20} {len(v)}")
