#!/usr/bin/env python3
"""
Compile the dbt models into ONE standalone Metabase query.

Why this exists
---------------
The reporting feed card should read `reporting.josiemaran_blended_performance`.
Until `dbt run` has built it, that table does not exist — so the Gsheet cannot
be wired up and nothing can be validated end to end.

This script renders the dbt models (macros expanded, ref()/source()/var()
resolved) into a chain of CTEs over the tables that DO exist today, and pastes
the feed card's SELECT on top. The result runs against Redshift as-is.

It is a GENERATOR, not a fork. The standalone card is derived from the same
model files, so the interim numbers and the post-dbt numbers cannot drift. Edit
the models, re-run this, done.

    python3 scripts/build_standalone_feed.py

Once `dbt run` has built the models, the standalone card is no longer needed —
swap the Metabase question to `metabase/01_reporting_feed.sql`, which is the
same final SELECT over the real table.
"""
import re, pathlib, sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
DB   = "josiemaran"

VARS = {"shopify_history_floor": "2026-03-25"}

# Models rendered as CTEs, in dependency order.
# Only the four models we own. facebook_campaign_performance and
# googleads_campaign_performance are deliberately NOT here: blended_performance
# reads the package reporting tables as sources instead, so dbt never rebuilds
# their lineage. See models/reporting/_sources.yml.
CHAIN = [
    "facebook_catalog_segment_performance",
    "shopify_sales_by_segment",
    "blended_performance",
]

# ref() targets that are real warehouse tables (built by the installed packages)
# rather than models in this project.
BASE_TABLES = {
    "facebook_performance_by_campaign":   f"reporting.{DB}_facebook_performance_by_campaign",
    "googleads_performance_by_campaign":  f"reporting.{DB}_googleads_performance_by_campaign",
    "shopify_daily_sales_by_order":       f"reporting.{DB}_shopify_daily_sales_by_order",
    "facebook_performance_by_ad":         f"reporting.{DB}_facebook_performance_by_ad",
    "tiktok_performance_by_ad":           f"reporting.{DB}_tiktok_performance_by_ad",
    "tiktok_performance_by_campaign":     f"reporting.{DB}_tiktok_performance_by_campaign",
}

SOURCE_SCHEMAS = {
    "facebook_catalog_raw": "facebook_raw",
    "jm_reporting":         "reporting",
}


def load_macros() -> dict:
    """Parse macros/*.sql into {name: (args, body)}."""
    macros = {}
    for path in sorted((ROOT / "macros").glob("*.sql")):
        text = path.read_text()
        for m in re.finditer(
            r"\{%\s*macro\s+(\w+)\s*\(([^)]*)\)\s*%\}(.*?)\{%\s*endmacro\s*%\}",
            text, re.S,
        ):
            name, args, body = m.group(1), m.group(2), m.group(3)
            arg_names = [a.strip() for a in args.split(",") if a.strip()]
            macros[name] = (arg_names, body)
    return macros


def strip_jinja_comments(sql: str) -> str:
    return re.sub(r"\{#.*?#\}", "", sql, flags=re.S)


def expand_macros(sql: str, macros: dict, depth: int = 0) -> str:
    """Substitute {{ macro_name('arg') }} with the macro body, args bound."""
    if depth > 8:
        raise RuntimeError("macro expansion too deep — recursive macro?")

    # Matches both `{{ macro('arg') }}` and the zero-arg `{{ macro() }}` form.
    pattern = re.compile(r"\{\{\s*(\w+)\s*\(([^{}]*?)\)\s*\}\}")

    def repl(m):
        name, raw_args = m.group(1), m.group(2)
        if name not in macros:
            return m.group(0)
        arg_names, body = macros[name]
        # split on top-level commas
        args, depth_p, cur = [], 0, ""
        for ch in raw_args:
            if ch in "([":
                depth_p += 1
            elif ch in ")]":
                depth_p -= 1
            if ch == "," and depth_p == 0:
                args.append(cur.strip()); cur = ""
            else:
                cur += ch
        if cur.strip():
            args.append(cur.strip())
        # strip quotes off literal args
        vals = [a[1:-1] if len(a) > 1 and a[0] == a[-1] and a[0] in "'\"" else a
                for a in args]
        out = body
        for an, av in zip(arg_names, vals):
            out = re.sub(r"\{\{\s*" + re.escape(an) + r"\s*\}\}", av, out)
        return "(" + strip_jinja_comments(out).strip() + ")"

    new = pattern.sub(repl, sql)
    if new != sql:
        return expand_macros(new, macros, depth + 1)
    return new


def render_model(name: str, macros: dict) -> str:
    path = ROOT / "models" / "reporting" / f"{name}.sql"
    sql = path.read_text()

    # config block and jinja comments
    sql = re.sub(r"\{\{\s*config\s*\(.*?\)\s*\}\}", "", sql, flags=re.S)
    sql = strip_jinja_comments(sql)
    sql = re.sub(r"/\*.*?\*/", "", sql, flags=re.S)          # block comments

    # vars
    for k, v in VARS.items():
        sql = re.sub(r"\{\{\s*var\(\s*['\"]" + k + r"['\"]\s*\)\s*\}\}", v, sql)

    # source()
    def src(m):
        schema = SOURCE_SCHEMAS[m.group(1)]
        return f"{schema}.{m.group(2)}"
    sql = re.sub(r"\{\{\s*source\(\s*['\"]([\w]+)['\"]\s*,\s*['\"]([\w]+)['\"]\s*\)\s*\}\}", src, sql)

    # macros (before ref, so a macro containing ref still resolves)
    sql = expand_macros(sql, macros)

    # ref()
    def ref(m):
        target = m.group(1)
        if target in BASE_TABLES:
            return BASE_TABLES[target]
        if target in CHAIN:
            return target            # becomes a CTE in this compilation
        raise RuntimeError(f"unmapped ref('{target}') — add it to BASE_TABLES or CHAIN")
    sql = re.sub(r"\{\{\s*ref\(\s*['\"]([\w]+)['\"]\s*\)\s*\}\}", ref, sql)

    leftover = re.findall(r"\{\{.*?\}\}|\{%.*?%\}", sql, flags=re.S)
    if leftover:
        raise RuntimeError(f"{name}: unrendered jinja: {leftover[:3]}")

    # a model body may open with its own `with` — strip it and keep the CTEs
    sql = sql.strip()
    if re.match(r"(?i)^with\b", sql):
        sql = re.sub(r"(?i)^with\s+", "", sql, count=1)
        # the model's internal CTEs become part of the outer WITH list, and the
        # model's final SELECT becomes the CTE named after the model
        return sql, True
    return sql, False


def main():
    macros = load_macros()
    if not macros:
        sys.exit("no macros parsed — check macros/*.sql")

    cte_blocks = []
    for name in CHAIN:
        body, had_with = render_model(name, macros)
        if had_with:
            # body is "<inner ctes>, ... final_select". Prefix inner CTE names so
            # two models can't collide on a shared helper name.
            body = re.sub(r"\n{3,}", "\n\n", body)
            inner, final = split_last_select(body)
            renamed_inner, renamed_final = prefix_ctes(inner, final, name)
            cte_blocks.extend(renamed_inner)
            cte_blocks.append((name, renamed_final))
        else:
            cte_blocks.append((name, body))

    feed = (ROOT / "metabase" / "01_reporting_feed.sql").read_text()
    feed_body = feed[feed.index("with\n"):]
    feed_body = re.sub(r"/\*.*?\*/", "", feed_body, flags=re.S)
    feed_body = re.sub(r"^\s*--.*$", "", feed_body, flags=re.M)
    feed_body = re.sub(r"\n{3,}", "\n\n", feed_body)
    feed_inner = feed_body[feed_body.index("with\n") + 5:]
    feed_inner = feed_inner.replace(
        f"reporting.{DB}_blended_performance", "blended_performance")

    header = f"""/*
  JM – Reporting Feed  ·  STANDALONE (pre-dbt) build
  ══════════════════════════════════════════════════════════════════════════════
  GENERATED by scripts/build_standalone_feed.py — do not hand-edit.
  Edit models/reporting/*.sql or metabase/01_reporting_feed.sql and re-run.

  Reads the base tables that exist today, so the Gsheet can be wired up before
  `dbt run` has built the reporting models. Numbers are identical to the
  dbt-backed card because both are compiled from the same model files.

  AFTER `dbt run`: point the Metabase question at
  metabase/01_reporting_feed.sql, which is this same final SELECT over
  reporting.{DB}_blended_performance. Then delete this file.
*/

with
"""
    parts = [f"{nm} as (\n{bd.strip()}\n)" for nm, bd in cte_blocks]
    out = header + ",\n\n".join(parts) + ",\n\n" + feed_inner.strip() + "\n"

    dest = ROOT / "metabase" / "generated" / "01_reporting_feed_standalone.sql"
    dest.write_text(out)
    print(f"wrote {dest.relative_to(ROOT)}  ({len(out):,} chars, {out.count(chr(10)):,} lines)")
    print(f"CTEs: {', '.join(nm for nm, _ in cte_blocks)}")


def split_last_select(body: str):
    """
    Split a rendered model body into ([(cte_name, cte_body), ...], final_select).

    Walks the CTE list explicitly. An earlier version looked for the *last*
    top-level ')' and treated everything after it as the final SELECT — which
    breaks the moment the final SELECT contains a function call, because
    `sum(cs_purchases)` closes a paren too. Scanning forward and checking
    whether each top-level chunk opens with `name as (` or with `select` is the
    only reliable way to find the boundary.
    """
    ctes, i, n = [], 0, len(body)
    while i < n:
        # skip whitespace, separating commas and comment lines
        while i < n and (body[i].isspace() or body[i] == ","):
            i += 1
        if i >= n:
            break
        if body[i : i + 2] == "--":
            nl = body.find("\n", i)
            i = n if nl == -1 else nl + 1
            continue
        # the final SELECT begins where a CTE definition does not
        if re.match(r"(?i)select\b", body[i : i + 8]):
            return ctes, body[i:]
        m = re.match(r"(\w+)\s+as\s*\(", body[i:])
        if not m:
            raise RuntimeError(
                "expected `<name> as (` or the final SELECT at:\n" + body[i : i + 200]
            )
        name = m.group(1)
        inner_start = i + m.end()
        depth, k = 1, inner_start
        while k < n and depth:
            if body[k] == "(":
                depth += 1
            elif body[k] == ")":
                depth -= 1
            k += 1
        if depth:
            raise RuntimeError(f"unbalanced parentheses in CTE `{name}`")
        ctes.append((name, body[inner_start : k - 1]))
        i = k
    raise RuntimeError("walked the whole body without finding a final SELECT")


def split_literals(text):
    """
    Split SQL into alternating (non_literal, literal) spans so identifier
    rewriting can skip anything inside single quotes.
    """
    spans, i, n, buf = [], 0, len(text), ""
    while i < n:
        if text[i] == "'":
            spans.append((buf, False)); buf = ""
            j = i + 1
            while j < n:
                if text[j] == "'":
                    if j + 1 < n and text[j + 1] == "'":   # escaped ''
                        j += 2; continue
                    break
                j += 1
            spans.append((text[i : j + 1], True))
            i = j + 1
        else:
            buf += text[i]; i += 1
    if buf:
        spans.append((buf, False))
    return spans


def prefix_ctes(inner, final, model):
    """
    Namespace a model's internal CTE names so two models can't collide on a
    shared helper name (`grains`, `orders`, `meta`, …).

    Rewrites identifiers ONLY outside string literals. An earlier version used a
    bare regex over the whole body, which renamed the *data* in the campaign-ID
    mapping: the literals 'google' and 'meta' collided with the CTE names
    `google` and `meta` and became 'blended_performance__google' /
    'blended_performance__meta'. The platform join then matched nothing and
    every campaign came out 'Unmapped' — with no error anywhere.
    """
    mapping = {nm: f"{model}__{nm}" for nm, _ in inner}

    def swap(text):
        out = []
        for span, is_literal in split_literals(text):
            if is_literal:
                out.append(span)
                continue
            for old, new in mapping.items():
                span = re.sub(rf"(?<![\w.]){re.escape(old)}(?![\w])", new, span)
            out.append(span)
        return "".join(out)

    renamed = [(mapping[nm], swap(bd)) for nm, bd in inner]
    return renamed, swap(final)


if __name__ == "__main__":
    main()
