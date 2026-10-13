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

    python3 scripts/build_standalone_feed.py            # (re)generate the standalone card
    python3 scripts/build_standalone_feed.py --check    # exit 1 if the committed file is stale

How the models are rendered
---------------------------
With real Jinja, the engine dbt itself uses. This used to be a hand-written regex
re-implementation of the few Jinja constructs the models happened to use (var,
source, ref, macro calls, one `if`). It stopped working the day a model used a
`for` loop and a package macro (the TikTok GMV Max CTE in blended_performance),
and nobody noticed for weeks because nothing ran it and the committed standalone
file simply went stale. Rendering with Jinja removes that class of failure: a new
construct just works, and a name the builder cannot resolve (an undeclared source,
an unknown macro, an unset var, an unmapped ref) is a loud error, never a quiet
miscompile. `var()` values come from dbt_project.yml and source schemas from the
`sources:` blocks in models/**/*.yml, so neither is a second copy to keep in step.

Once `dbt run` has built the models, the standalone card is no longer needed —
swap the Metabase question to `metabase/01_reporting_feed.sql`, which is the
same final SELECT over the real table.
"""
import re, pathlib, sys
from types import SimpleNamespace

try:
    import jinja2
    import yaml
except ImportError as exc:
    sys.exit(f"{exc.name} is not installed. It ships with dbt: `pip install {exc.name}`, "
             f"or run this with the dbt venv's python (/home/ubuntu/.dbt-venv/bin/python).")

ROOT = pathlib.Path(__file__).resolve().parent.parent
DB   = "josiemaran"

# The project's own vars, straight from dbt_project.yml, so the standalone card can
# never disagree with dbt about week_start or the Shopify history floor.
VARS = dict((yaml.safe_load((ROOT / "dbt_project.yml").read_text()) or {}).get("vars") or {})

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

def _declared_sources() -> dict:
    """{source name: schema} from every `sources:` block in models/**/*.yml."""
    out = {}
    for path in sorted((ROOT / "models").rglob("*.yml")):
        for src in (yaml.safe_load(path.read_text()) or {}).get("sources") or []:
            out[src["name"]] = src.get("schema", src["name"])     # dbt: schema defaults to the name
    return out


# Derived, not hand-kept: this map falling behind _sources.yml (tiktok_gmv_raw) is what
# broke the builder. build_sheet_cards.py may still add entries to it in-process.
SOURCE_SCHEMAS = _declared_sources()


# Package macros a model may call. Listed, not globbed: the packages hold hundreds of
# macros, many written against dbt's own Jinja extensions and not parseable by plain
# Jinja, and loading them all would let one silently shadow a macro of ours.
PACKAGE_MACROS = [
    "dbt_packages/bolt_dbt_utils/macros/snippets/utils/get_date_parts.sql",
]


def _var(name, default=None):
    if name in VARS:
        return VARS[name]
    if default is not None:
        return default
    raise KeyError(f"var('{name}') is not set in dbt_project.yml and has no default")


def _source(source_name, table):
    if source_name not in SOURCE_SCHEMAS:
        raise KeyError(f"source('{source_name}', ...) is not declared in any models/**/*.yml")
    return f"{SOURCE_SCHEMAS[source_name]}.{table}"


def _ref(target):
    if target in BASE_TABLES:
        return BASE_TABLES[target]
    if target in CHAIN:
        return target            # becomes a CTE in this compilation
    raise RuntimeError(f"unmapped ref('{target}') — add it to BASE_TABLES or CHAIN")


def _env() -> "jinja2.Environment":
    env = jinja2.Environment(undefined=jinja2.StrictUndefined, extensions=["jinja2.ext.do"])
    env.globals.update(
        var=_var, ref=_ref, source=_source,
        config=lambda *a, **k: "",                   # {{ config(...) }} renders to nothing, as in dbt
        target=SimpleNamespace(database=DB, name=DB, schema="reporting", type="redshift"),
    )
    return env


def load_macros() -> dict:
    """{name: macro} for every project macro plus the package macros models call."""
    texts = [p.read_text() for p in sorted((ROOT / "macros").glob("*.sql"))]
    for rel in PACKAGE_MACROS:
        path = ROOT / rel
        if not path.exists():
            sys.exit(f"{rel} not found — run `dbt deps` first")
        texts.append(path.read_text())
    module = _env().from_string("\n".join(texts)).module
    macros = {k: v for k, v in vars(module).items() if isinstance(v, jinja2.runtime.Macro)}
    if not macros:
        sys.exit("no macros parsed — check macros/*.sql")
    return macros


def render_model(name: str, macros: dict):
    """
    Render a model (or a test, as '../../tests/<name>') to plain SQL.
    Returns (sql, had_with); when the body opens with its own WITH, that keyword is
    stripped so its CTEs can join the outer list.
    """
    path = ROOT / "models" / "reporting" / f"{name}.sql"
    sql = _env().from_string(path.read_text()).render(**macros)

    # Comments carry no logic and get in the way of splitting CTEs apart. Full-line `--`
    # first, so a stray `/*` inside one cannot swallow code up to the next `*/`.
    sql = re.sub(r"^[ \t]*--.*$", "", sql, flags=re.M)
    sql = re.sub(r"/\*.*?\*/", "", sql, flags=re.S)
    sql = re.sub(r"\n{3,}", "\n\n", sql).strip()

    if re.match(r"(?i)^with\b", sql):
        # the model's internal CTEs become part of the outer WITH list, and the
        # model's final SELECT becomes the CTE named after the model
        return re.sub(r"(?i)^with\s+", "", sql, count=1), True
    return sql, False


def avoid_month_intervals(sql: str) -> str:
    """
    Rewrite `x - interval 'N month'` as `dateadd(month, -N, x)`.

    Redshift folds a month interval as a constant when the card reads a stored table, but
    here the same predicate sits on a computed CTE (blended_performance is a chain of
    aggregates) and the planner pushes it down to the compute nodes, which cannot evaluate
    it: "Interval values with month or year parts are not supported". dateadd() is
    equivalent and always supported. Only the two shapes the card uses are rewritten; any
    month or year interval that is left is an error, so a new one fails here, loudly,
    rather than 155 seconds into a query.
    """
    sql = re.sub(r"(date_trunc\('month', current_date\)) - interval '(\d+) months?'",
                 r"dateadd(month, -\2, \1)", sql)
    sql = re.sub(r"date_trunc\('month', current_date - interval '(\d+) months?'\)",
                 r"date_trunc('month', dateadd(month, -\1, current_date))", sql)
    left = re.findall(r"interval\s+'\d+\s*(?:month|year)s?'", sql, flags=re.I)
    if left:
        sys.exit(f"{len(left)} month/year interval(s) left in the standalone SQL, e.g. {left[0]!r}: "
                 f"Redshift cannot run them on a computed CTE. Add a rewrite to avoid_month_intervals().")
    return sql


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
  Edit the models in models/reporting/ or metabase/01_reporting_feed.sql and re-run.

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

    out = avoid_month_intervals(out)

    # Postgres-family parsers (Redshift) NEST block comments, so a stray `/*` inside the
    # header -- the glob `models/reporting/*.sql` was one -- leaves it unterminated and the
    # whole file fails to parse. Model and card comments are stripped above, so only the
    # header's single pair should remain.
    if out.count("/*") != out.count("*/"):
        sys.exit(f"generated SQL has {out.count('/*')} comment opens but {out.count('*/')} closes: "
                 f"a `/*` inside a block comment (a glob like models/*.sql?) leaves it unterminated")

    dest = ROOT / "metabase" / "generated" / "01_reporting_feed_standalone.sql"
    if "--check" in sys.argv:
        if not dest.exists() or dest.read_text() != out:
            sys.exit(f"STALE: {dest.relative_to(ROOT)} no longer matches the models and the card — "
                     f"run `python3 scripts/build_standalone_feed.py`")
        print(f"ok: {dest.relative_to(ROOT)} is current")
        return
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

    The same care applies to COLUMN names, not just literals: see the note in `swap`.
    """
    mapping = {nm: f"{model}__{nm}" for nm, _ in inner}

    def swap(text):
        out = []
        for span, is_literal in split_literals(text):
            if is_literal:
                out.append(span)
                continue
            for old, new in mapping.items():
                # A CTE is only ever REFERENCED as a relation (after FROM / JOIN) or by
                # qualifying a column with its own name (`old.col`). Renaming every bare
                # occurrence also renamed output COLUMNS that share a CTE's name: with a CTE
                # called `orders`, `count(distinct order_id) as orders` became
                # `... as shopify_sales_by_segment__orders` and the model's `orders` column
                # vanished, so blended_performance failed with "column orders does not exist".
                span = re.sub(rf"(?i)\b(from|join)(\s+){re.escape(old)}(?![\w.])",
                              rf"\1\2{new}", span)
                span = re.sub(rf"(?<![\w.]){re.escape(old)}(?=\.)", new, span)
            out.append(span)
        return "".join(out)

    renamed = [(mapping[nm], swap(bd)) for nm, bd in inner]
    return renamed, swap(final)


if __name__ == "__main__":
    main()
