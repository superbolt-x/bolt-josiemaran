#!/usr/bin/env python3
"""
Static checks on a generated standalone SQL file.

Catches the failure classes that assembling many rendered models introduces —
a CTE referenced but never defined, two CTEs sharing a name, unbalanced
parentheses, leftover Jinja, and UNION branches with differing column counts.

    python3 scripts/validate_sql.py metabase/generated/01_reporting_feed_standalone.sql
"""
import re, sys, pathlib

def strip_comments(sql):
    sql = re.sub(r"/\*.*?\*/", " ", sql, flags=re.S)
    sql = re.sub(r"--[^\n]*", " ", sql)
    return sql

def main(path):
    raw = pathlib.Path(path).read_text()
    sql = strip_comments(raw)
    fails = []

    # 1 — leftover Jinja
    jinja = re.findall(r"\{\{.*?\}\}|\{%.*?%\}|\{#.*?#\}", sql, flags=re.S)
    print(f"{'✓' if not jinja else '✗'} no unrendered Jinja"
          + ("" if not jinja else f"  → {jinja[:3]}"))
    if jinja: fails.append("jinja")

    # 2 — parentheses balance
    depth = mn = 0
    for ch in sql:
        if ch == "(": depth += 1
        elif ch == ")":
            depth -= 1; mn = min(mn, depth)
    print(f"{'✓' if depth == 0 and mn == 0 else '✗'} parentheses balanced "
          f"(final={depth}, min={mn})")
    if depth or mn: fails.append("parens")

    # 3 — CTE names: defined vs duplicated
    defined = re.findall(r"(?m)^(\w+) as \($", sql)
    dupes = {n for n in defined if defined.count(n) > 1}
    print(f"{'✓' if not dupes else '✗'} {len(defined)} CTEs, no duplicate names"
          + ("" if not dupes else f"  → {sorted(dupes)}"))
    if dupes: fails.append("dupe-cte")

    # 4 — every bare FROM/JOIN target is a CTE, a schema-qualified table, or an alias
    known = set(defined)
    # collect subquery aliases like  ) x  /  ) as x
    aliases = set(re.findall(r"\)\s*(?:as\s+)?(\w+)\b", sql))
    refs = re.findall(r"(?i)\b(?:from|join)\s+([a-z_][\w.]*)", sql)
    KEYWORDS = {"grouping", "select", "sets"}
    bad = sorted({
        r for r in refs
        if "." not in r
        and r.lower() not in KEYWORDS
        and r not in known
        and r not in aliases
    })
    print(f"{'✓' if not bad else '✗'} all {len(set(refs))} FROM/JOIN targets resolve"
          + ("" if not bad else f"  → UNDEFINED: {bad}"))
    if bad: fails.append("undefined-ref")

    # 5 — UNION ALL branch column counts, per contiguous union chain
    def col_count(select_body):
        depth, cnt = 0, 1
        for ch in select_body:
            if ch in "([": depth += 1
            elif ch in ")]": depth -= 1
            elif ch == "," and depth == 0: cnt += 1
        return cnt

    chains, bad_unions = 0, []
    for m in re.finditer(r"(?is)\bselect\b(.*?)(?=\bfrom\b)", sql):
        pass  # per-branch counting is done below on explicit chains

    # find "select ... union all select ..." runs inside each CTE body
    for cte_m in re.finditer(r"(?m)^(\w+) as \($", sql):
        name = cte_m.group(1)
        start = cte_m.end()
        depth, k = 1, start
        while k < len(sql) and depth:
            if sql[k] == "(": depth += 1
            elif sql[k] == ")": depth -= 1
            k += 1
        body = sql[start:k-1]
        if not re.search(r"(?i)\bunion\s+all\b", body):
            continue
        # split at TOP-LEVEL "union all" only
        parts, depth, last = [], 0, 0
        for m in re.finditer(r"(?i)\bunion\s+all\b", body):
            seg = body[last:m.start()]
            d = seg.count("(") - seg.count(")")
            depth += d
            if depth == 0:
                parts.append(body[last:m.start()]); last = m.end()
        parts.append(body[last:])
        if len(parts) < 2:
            continue
        chains += 1
        counts = []
        for p in parts:
            sm = re.search(r"(?is)\bselect\b(.*?)(?=\bfrom\b|$)", p)
            if sm: counts.append(col_count(sm.group(1)))
        if len(set(counts)) > 1:
            bad_unions.append((name, counts))
    print(f"{'✓' if not bad_unions else '✗'} {chains} UNION chains, branches aligned"
          + ("" if not bad_unions else f"  → {bad_unions}"))
    if bad_unions: fails.append("union-mismatch")

    # 6 — an unbound macro parameter leaked into the SQL as a column name.
    # jm_period_start passes its arg to a nested jm_week_start call; if the
    # compiler fails to bind it, the output references a column literally
    # called `date_col` / `granularity_col` and Redshift errors at run time.
    params = sorted(set(re.findall(r"\b(date_col|granularity_col|segment|campaign_name)\b(?=\s*[+),])", sql)) & {"date_col", "granularity_col"})
    print(f"{'✓' if not params else '✗'} no unbound macro parameters"
          + ("" if not params else f"  → {params}"))
    if params: fails.append("unbound-macro-arg")

    # 7 — correlated subquery. Redshift rejects these with "This type of
    # correlated subquery pattern is not supported due to internal error" once
    # there is more than one correlation predicate against a CTE. Use a
    # LEFT JOIN + sentinel IS NULL anti-join instead.
    corr = re.findall(r"(?i)\b(?:not\s+)?exists\s*\(", sql)
    print(f"{'✓' if not corr else '✗'} no EXISTS / NOT EXISTS subquery"
          + ("" if not corr else f"  → {len(corr)} found"))
    if corr: fails.append("correlated-subquery")

    # 8 — a CTE referenced more than once, where one reference sits inside a
    # join predicate. Redshift throws "This type of correlated subquery pattern
    # is not supported" for that plan shape even though every piece is valid on
    # its own. Warn rather than fail: multiple plain FROM references are fine,
    # it is the join-predicate combination that breaks.
    defined_ctes = set(re.findall(r"(?m)^(\w+) as \($", sql))
    multi = sorted(
        c for c in defined_ctes
        if len(re.findall(rf"(?i)(?:from|join)\s+{re.escape(c)}\b", sql)) > 1
    )
    print(f"{'✓' if not multi else '!'} no CTE referenced more than once"
          + ("" if not multi else f"  → {multi} (check none is in a join predicate)"))

    # 9 — namespacing leaked into a string literal
    # The compiler prefixes a model's internal CTE names to avoid collisions.
    # If that rewrite touches a string literal it corrupts DATA, not just
    # identifiers — 'google' became 'blended_performance__google' once, which
    # silently made every campaign 'Unmapped'. A literal of the form
    # <word>__<word> is almost always this bug.
    literals = re.findall(r"'([a-z_]+__[a-z_]+)'", sql)
    print(f"{'✓' if not literals else '✗'} no CTE prefix inside a string literal"
          + ("" if not literals else f"  → {sorted(set(literals))[:5]}"))
    if literals: fails.append("literal-polluted")

    print(f"\n{'PASS' if not fails else 'FAIL: ' + ', '.join(fails)}"
          f"   ({len(raw):,} chars, {raw.count(chr(10)):,} lines)")
    return 1 if fails else 0

if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
