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

values = ",\n".join(
    "        ('{p}', '{cid}', '{seg}', '{bl}', {dtc})".format(
        p=r["platform"].strip(), cid=r["campaign_id"].strip(),
        seg=r["segment"].strip().replace("'", "''"),
        bl=r["business_line"].strip(), dtc=r["dtc_overall"].strip().lower())
    for r in rows
)

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
#}}

{{% macro jm_campaign_segments() %}}
    select * from (
        values
{values}
    ) as t(platform, campaign_id, segment, business_line, dtc_overall)
{{% endmacro %}}


{{#
  Market is read off the segment rather than a campaign tag — the segment names
  from the deck already encode it, and the tags do not agree with each other.
#}}
{{% macro jm_market_from_segment(segment) %}}
    case
        when {{{{ segment }}}} like '%US%' then 'US'
        when {{{{ segment }}}} like '%CA%' then 'CA'
        when {{{{ segment }}}} in ('Meta Overall', 'Google Overall') then 'US'
        else 'Unknown'
    end
{{% endmacro %}}
""")
print(f"wrote {DEST.relative_to(ROOT)} — {len(rows)} campaigns, {len(segments)} segments")
for seg, v in sorted(by_seg.items()):
    print(f"  {seg:<20} {len(v)}")
