#!/usr/bin/env python3
"""Assert the Gsheet script and the Metabase card still agree.

Two files encode one contract: the card decides which column holds what and how
lookup_key is spelled, and build_gsheet.gs hardcodes column letters and rebuilds
that key in a formula. Nothing links them, so a drift is silent — the sheet just
returns blanks, or worse, the wrong column's number.

That is not hypothetical. The MTD tab came back completely empty because the two
sides disagreed about the period half of the key, and it took a screenshot to
notice. This check makes that a build failure instead.

    python3 scripts/check_feed_contract.py
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CARD = ROOT / "metabase" / "01_reporting_feed.sql"
GS = ROOT / "scripts" / "build_gsheet.gs"


def col_letter(n: int) -> str:
    s = ""
    while n > 0:
        n, m = divmod(n - 1, 26)
        s = chr(65 + m) + s
    return s


def card_columns(sql: str) -> list[str]:
    """Column names of the card's final select, in order."""
    head = sql[: sql.rindex("from unioned")]
    final = head[head.rindex("\nselect\n") + len("\nselect\n") :]

    # drop comments and keep string literals intact
    out, i, n = [], 0, len(final)
    while i < n:
        if final[i : i + 2] == "--":
            j = final.find("\n", i)
            i = j if j >= 0 else n
            continue
        if final[i : i + 2] == "/*":
            j = final.find("*/", i + 2)
            i = (j + 2) if j >= 0 else n
            continue
        if final[i] == "'":
            j = i + 1
            while j < n and final[j] != "'":
                j += 1
            out.append(final[i : j + 1])
            i = j + 1
            continue
        out.append(final[i])
        i += 1

    items, buf, depth = [], "", 0
    for ch in "".join(out):
        if ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
        if ch == "," and depth == 0:
            items.append(buf)
            buf = ""
            continue
        buf += ch
    if buf.strip():
        items.append(buf)

    names = []
    for it in items:
        t = it.strip()
        if not t:
            continue
        m = re.search(r"\bas\s+([a-z_0-9]+)\s*$", t, re.S | re.I)
        if m:
            names.append(m.group(1))
        else:
            ident = re.findall(r"[a-z_0-9]+", t.replace("\n", " "), re.I)
            if ident:
                names.append(ident[-1])
    return names


def main() -> int:
    sql = CARD.read_text()
    gs = GS.read_text()
    cols = card_columns(sql)
    pos = {c: col_letter(i + 1) for i, c in enumerate(cols)}
    fails, checks = [], 0

    # 1 — the range constant must span exactly the card's width
    checks += 1
    want = f"$A:${col_letter(len(cols))}"
    m = re.search(r"var COLS\s*=\s*'([^']+)'", gs)
    if not m or m.group(1) != want:
        fails.append(f"COLS is {m.group(1) if m else '?'}, card is {len(cols)} wide -> {want}")

    # 2 — each single-column constant must point at the column it is named for
    for const, col in [("PSTART", "period_start"), ("KEY", "lookup_key"),
                       ("VALID", "data_valid"), ("FEEDBACK", "has_catalog_feedback")]:
        checks += 1
        m = re.search(rf"var {const}\s*=\s*'\$([A-Z]+):\$[A-Z]+'", gs)
        if not m:
            fails.append(f"{const} not found in {GS.name}")
        elif m.group(1) != pos.get(col):
            fails.append(f"{const} -> ${m.group(1)}, but {col} is at ${pos.get(col)}")

    # 3 — every metric the script asks for by header name must exist in the card
    for metric in sorted(set(re.findall(r"\[\s*'[^']*',\s*'([a-z_0-9]+)',\s*'[^']*'\s*\]", gs))):
        checks += 1
        if metric not in pos:
            fails.append(f"SHAPES asks for '{metric}', which the card does not emit")

    # 4 — the key the script rebuilds must match the key the card concatenates
    checks += 1
    if "grain || '|'" not in sql:
        fails.append("card's lookup_key omits grain; 'month' and 'mtd' would collide")
    checks += 1
    key_fn = re.search(r"function key_\([^)]*\)\s*\{(.*?)\n\}", gs, re.S)
    if not key_fn:
        fails.append("build_gsheet.gs has no key_() function")
    elif "grain" not in key_fn.group(1).split("TEXT(")[0]:
        fails.append("build_gsheet.gs key_() does not put grain in the key")

    # 5 — the period format per grain has to be identical on both sides
    card_fmt = dict(re.findall(r"when '(week|month|mtd)'\s+then to_char\(period_start, '([A-Z\-]+)'\)",
                               sql[sql.rindex("as lookup_key") - 900 : sql.rindex("as lookup_key")]))
    gs_fmt = dict(re.findall(r"(\w+):\s*\{[^}]*key:\s*'([a-z\-]+)'", gs))
    for grain, cf in card_fmt.items():
        checks += 1
        if gs_fmt.get(grain, "").upper() != cf:
            fails.append(f"grain '{grain}': card writes {cf}, sheet rebuilds "
                         f"{gs_fmt.get(grain, '(missing)').upper()}")

    # 6 — every grain the script reads must be a grain the card emits
    emitted = set(re.findall(r"branch\(lv, \"\w+\", \"(\w+)\"\)",
                             (ROOT / "scripts" / "gen_reporting_feed.py").read_text()))
    for grain in set(re.findall(r"(?:chartG|g)rain: '(\w+)'", gs)):
        checks += 1
        if grain not in emitted:
            fails.append(f"TABS uses grain '{grain}', card emits only {sorted(emitted)}")

    print(f"feed contract: {checks} checks")
    for f in fails:
        print(f"  FAIL  {f}")
    if not fails:
        print(f"  PASS  {len(cols)} columns A:{col_letter(len(cols))}, "
              f"grains {sorted(emitted)}")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
