#!/usr/bin/env python3
"""
Tests for scripts/build_pacing_tabs.gs and scripts/build_sales_tab.gs, run in a real V8
with a mock Sheets API.

    pip install py-mini-racer
    python3 scripts/test_sheet_tabs.py

Why this exists: Apps Script cannot be run outside Google, so a bug in the chart
builder would otherwise first show up in the client's sheet. This loads the
actual .gs source (not a copy) and exercises it against a mock SpreadsheetApp.

What the mock is strict about, because real Apps Script is:
  - sheet.clear() leaves charts alone, as the real one does;
  - a chart returned by modify() is a GENERIC builder with no setStacked() and no
    asColumnChart(), so using either on the edit-in-place path raises here too.

What it cannot tell you: how Google actually renders the chart. The first run in
the real sheet still has to be looked at.
"""
import json, pathlib, re, sys, unittest

try:
    from py_mini_racer import MiniRacer
except ImportError:
    print("SKIP: py-mini-racer is not installed (pip install py-mini-racer)")
    sys.exit(0)

ROOT = pathlib.Path(__file__).resolve().parent.parent
GS = (ROOT / "scripts" / "build_pacing_tabs.gs").read_text()
SALES_GS = (ROOT / "scripts" / "build_sales_tab.gs").read_text()


def with_id(src, name, value):
    """Pin a card id constant, whatever real id is committed in the .gs file."""
    out, n = re.subn(rf"var {name} = \d+;", f"var {name} = {value};", src)
    assert n == 1, f"{name} not found exactly once"
    return out

PRELUDE = r"""
var Logger = { log: function () {} };
var Utilities = { formatDate: function (d) { return d.toISOString().slice(0, 10); },
                  parseCsv: function (t) { return t.trim().split('\n').map(function (l) { return l.split(','); }); } };
var UrlFetchApp = { calls: [], next: null, fetch: function (u, o) { UrlFetchApp.calls.push({ url: u, opts: o }); return UrlFetchApp.next; } };
function mbConfig_() { return { url: 'https://mb.example', key: 'KEY' }; }
function fakeResponse(code, text) { return { getResponseCode: function () { return code; }, getContentText: function () { return text; } }; }
var SpreadsheetApp = { getActive: function () { return CURRENT_SS; } };
var CURRENT_SS = null;

function makeBuilder(existing) {
  var b = { opts: {}, ranges: [], stacked: false, numHeaders: 0, pos: null, id: null };
  if (existing) {
    b.opts = JSON.parse(JSON.stringify(existing.opts)); b.ranges = existing.ranges.slice();
    b.stacked = existing.stacked; b.id = existing.id;
  }
  if (!existing) {
    b.asColumnChart = function () { b.kind = 'column'; return b; };
    b.setStacked = function () { b.stacked = true; return b; };
  }
  b.clearRanges = function () { b.ranges = []; return b; };
  b.addRange = function (r) { b.ranges.push(r.desc); return b; };
  b.setNumHeaders = function (n) { b.numHeaders = n; return b; };
  b.setOption = function (k, v) { b.opts[k] = JSON.parse(JSON.stringify(v)); if (k === 'isStacked') b.stacked = !!v; return b; };
  b.setPosition = function (r, c) { b.pos = [r, c]; return b; };
  b.build = function () { return chartOf(b); };
  return b;
}
function chartOf(b) {
  var ch = { id: b.id, opts: b.opts, ranges: b.ranges, stacked: b.stacked, pos: b.pos };
  ch.getOptions = function () { return { get: function (k) { return ch.opts[k]; } }; };
  ch.modify = function () { return makeBuilder(ch); };
  return ch;
}
var NEXT_CHART_ID = 1;
function makeSheet(name) {
  var sh = { name: name, cells: {}, charts: [], log: [] };
  sh.setFrozenRows = function () {};
  var key = function (r, c) { return r + ',' + c; };
  var cell = function (r, c) { return sh.cells[key(r, c)] || (sh.cells[key(r, c)] = { v: null, f: null, nf: null }); };
  sh.getRange = function (r, c, nr, nc) {
    nr = nr || 1; nc = nc || 1;
    var rng = { desc: [r, c, nr, nc] };
    rng.setValue = function (v) { var x = cell(r, c); x.v = v; x.f = null; return rng; };
    rng.setValues = function (vals) {
      sh.log.push('values');
      for (var i = 0; i < nr; i++) for (var j = 0; j < nc; j++) { var x = cell(r + i, c + j); x.v = vals[i][j]; x.f = null; }
      return rng;
    };
    rng.setFormula = function (f) { var x = cell(r, c); x.f = f; x.v = null; return rng; };
    rng.setNumberFormat = function (nf) { sh.log.push('fmt'); for (var i = 0; i < nr; i++) for (var j = 0; j < nc; j++) cell(r + i, c + j).nf = nf; return rng; };
    rng.getValue = function () { var x = sh.cells[key(r, c)]; return x && x.v !== null ? x.v : ''; };
    ['setFontWeight', 'setFontSize', 'setFontColor'].forEach(function (m) { rng[m] = function () { return rng; }; });
    return rng;
  };
  sh.clear = function () { sh.cells = {}; return sh; };          // charts survive, as in the real API
  sh.clearConditionalFormatRules = function () {};
  sh.getCharts = function () { return sh.charts.slice(); };
  sh.newChart = function () { return makeBuilder(null); };
  sh.insertChart = function (ch) { ch.id = NEXT_CHART_ID++; sh.charts.push(ch); };
  sh.updateChart = function (ch) { for (var i = 0; i < sh.charts.length; i++) if (sh.charts[i].id === ch.id) sh.charts[i] = ch; };
  sh.removeChart = function (ch) { sh.charts = sh.charts.filter(function (x) { return x.id !== ch.id; }); };
  return sh;
}
function makeSpreadsheet(feedName, feedValues) {
  var ss = { sheets: {}, toasts: [] };
  ss.getSheetByName = function (n) { return ss.sheets[n] || null; };
  ss.insertSheet = function (n) { return (ss.sheets[n] = makeSheet(n)); };
  ss.getSpreadsheetTimeZone = function () { return 'America/New_York'; };
  ss.toast = function (m) { ss.toasts.push(m); };
  var feed = ss.insertSheet(feedName);
  feed.getLastRow = function () { return feedValues.length; };
  feed.getDataRange = function () { return { getValues: function () { return feedValues; } }; };
  return ss;
}
"""

COLS = ["date", "month_start", "business_unit", "platform", "campaign_key", "legend_label",
        "stack_order", "forecast_color", "actual_color", "forecast_budget", "actual_spend", "is_actual"]


def feed_rows(through, month="2026-09-01", days=30, unit="sephora_us"):
    """A Sephora-US-shaped month: 4 lines, actuals through `through` (a day number), forecast after."""
    lines = [("meta", "us_traffic", "Meta US Traffic", 1, "#A4C2F4", "#B7B7B7", 1800.0),
             ("meta", "us_collab", "Meta US Collab", 2, "#3C78D8", "#999999", 250.0),
             ("meta", "new_us_collab", "New US Collab", 3, "#2343AA", "#666666", 0.0),
             ("tiktok", "us_traffic", "TikTok US Traffic", 4, "#FF9900", "#434343", 600.0)]
    rows = []
    for d in range(1, days + 1):
        iso = f"{month[:8]}{d:02d}"
        for plat, key, label, order, fc, ac, base in lines:
            # a line budgeted at $0 also spends $0 (the all-zero line the script drops)
            actual = ((base + d) if base else 0.0) if d <= through else ""
            rows.append([iso, month, unit, plat, key, label, order, fc, ac, base, actual,
                         1 if d <= through else 0])
    return rows


class PacingTabs(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.ctx = MiniRacer()
        cls.ctx.eval(with_id(GS, "PACING_CARD_ID", 99))
        cls.ctx.eval(PRELUDE)

    def js(self, expr):
        return json.loads(self.ctx.eval(f"JSON.stringify({expr})"))

    def build(self, rows, name="s"):
        self.ctx.eval(f"var {name} = makeSpreadsheet('budget pacing @ 99', {json.dumps([COLS] + rows)});")
        self.ctx.eval(f"buildPacingTabs_({name});")
        return name

    # ── pure logic ───────────────────────────────────────────────────────────
    def test_month_follows_the_data_and_budget_tab_looks_ahead(self):
        rows = [dict(zip(COLS, r)) for r in feed_rows(28)]
        parsed = self.js(f"pacingParseFeed_({json.dumps([COLS] + feed_rows(28))}, 'UTC')")
        self.assertEqual(self.js(f"pacingPickMonths_({json.dumps(parsed)}, '')")["pacing"], "2026-09-01")
        # October budgeted too -> the DoD tab moves on to October, pacing stays on September
        octo = feed_rows(0, month="2026-10-01", days=31)
        both = self.js(f"pacingParseFeed_({json.dumps([COLS] + feed_rows(28) + octo)}, 'UTC')")
        m = self.js(f"pacingPickMonths_({json.dumps(both)}, '')")
        self.assertEqual((m["pacing"], m["budget"]), ("2026-09-01", "2026-10-01"))

    def test_pacing_has_one_grey_actual_series_then_a_forecast_series_per_campaign(self):
        rows = self.js(f"pacingParseFeed_({json.dumps([COLS] + feed_rows(28))}, 'UTC')")
        m = self.js(f"pacingUnitModel_({json.dumps(rows)}, 'sephora_us', '2026-09-01', 'pacing')")
        heads = [c["header"] for c in m["columns"]]
        self.assertEqual(heads, ["Actual spend", "Meta US Traffic", "Meta US Collab",
                                 "TikTok US Traffic"])         # New US Collab is all zero: dropped
        self.assertEqual(len(m["matrix"]), 30)
        # day 1 is over: ONE actual cell holding the sum across campaigns, forecasts blank
        self.assertEqual(m["matrix"][0], ["9/1", (1800 + 1) + (250 + 1) + (600 + 1), "", "", ""])
        # day 29 is still forecast: the reverse, one value per campaign, actual blank (not 0)
        self.assertEqual(m["matrix"][28], ["9/29", "", 1800.0, 250.0, 600.0])

    def test_no_actual_column_at_all_when_no_day_is_over_yet(self):
        rows = self.js(f"pacingParseFeed_({json.dumps([COLS] + feed_rows(0))}, 'UTC')")
        m = self.js(f"pacingUnitModel_({json.dumps(rows)}, 'sephora_us', '2026-09-01', 'pacing')")
        self.assertNotIn("Actual spend", [c["header"] for c in m["columns"]])

    def test_a_day_can_be_part_actual_part_forecast_when_platforms_cross_over(self):
        """Google behind Meta: on the crossover day the grey is Meta's actual and Google stays forecast."""
        rows = feed_rows(10)
        for r in rows:                                   # make TikTok lag: its day 10 is still forecast
            if r[3] == "tiktok" and r[0].endswith("-10"):
                r[10], r[11] = "", 0
        parsed = self.js(f"pacingParseFeed_({json.dumps([COLS] + rows)}, 'UTC')")
        m = self.js(f"pacingUnitModel_({json.dumps(parsed)}, 'sephora_us', '2026-09-01', 'pacing')")
        day10 = m["matrix"][9]
        self.assertEqual(day10[0], "9/10")
        self.assertEqual(day10[1], (1800 + 10) + (250 + 10))        # only the platforms that are over
        self.assertEqual(day10[4], 600.0)                           # TikTok still shows its forecast

    def test_a_day_is_either_actual_or_forecast_when_the_cutover_is_uniform(self):
        rows = self.js(f"pacingParseFeed_({json.dumps([COLS] + feed_rows(10))}, 'UTC')")
        m = self.js(f"pacingUnitModel_({json.dumps(rows)}, 'sephora_us', '2026-09-01', 'pacing')")
        for line in m["matrix"]:
            actual, forecasts = line[1], line[2:]
            self.assertFalse(actual != "" and any(v != "" for v in forecasts), line)
            self.assertTrue(actual != "" or any(v != "" for v in forecasts), line)   # never an empty day

    def test_stats_match_hand_calculation(self):
        rows = self.js(f"pacingParseFeed_({json.dumps([COLS] + feed_rows(28))}, 'UTC')")
        s = self.js(f"pacingUnitModel_({json.dumps(rows)}, 'sephora_us', '2026-09-01', 'pacing')")["stats"]
        self.assertEqual(s["elapsedDays"], 28)
        self.assertEqual(s["daysInMonth"], 30)
        self.assertAlmostEqual(s["planned"], (1800 + 250 + 0 + 600) * 30)
        self.assertAlmostEqual(s["spent"], sum((1800 + d) + (250 + d) + (600 + d) for d in range(1, 29)))

    def test_budget_mode_has_no_actual_columns_and_fills_every_day(self):
        rows = self.js(f"pacingParseFeed_({json.dumps([COLS] + feed_rows(28))}, 'UTC')")
        m = self.js(f"pacingUnitModel_({json.dumps(rows)}, 'sephora_us', '2026-09-01', 'budget')")
        self.assertTrue(all(c["kind"] == "forecast" for c in m["columns"]))
        self.assertTrue(all(v != "" for line in m["matrix"] for v in line))

    def test_a_missing_column_in_the_feed_is_a_clear_error(self):
        bad = [c for c in COLS if c != "is_actual"]
        with self.assertRaises(Exception) as cm:
            self.js(f"pacingParseFeed_({json.dumps([bad])}, 'UTC')")
        self.assertIn("is_actual", str(cm.exception))

    # ── the sheet writer ─────────────────────────────────────────────────────
    def test_builds_both_tabs_with_one_chart_per_business_unit_that_has_data(self):
        rows = feed_rows(28)
        s = self.build(rows)
        for tab in ("Budget Pacing", "DoD Budgets"):
            self.assertEqual(self.js(f"{s}.sheets['{tab}'].charts.length"), 1, tab)  # only sephora_us has rows

    def test_chart_series_colours(self):
        s = self.build(feed_rows(28))
        ch = self.js(f"{s}.sheets['Budget Pacing'].charts[0]")
        self.assertEqual(ch["opts"]["title"], "Sephora US — Budget Pacing")     # no month: stable identity
        ser = ch["opts"]["series"]
        self.assertEqual(len(ser), 4)                       # one grey actual + three campaigns, so a short legend
        self.assertEqual([ser[str(i)]["color"] for i in range(4)],
                         ["#999999", "#A4C2F4", "#3C78D8", "#FF9900"])
        # Sheets ignores visibleInLegend, so it must not be relied on (or set)
        self.assertTrue(all("visibleInLegend" not in v for v in ser.values()))
        self.assertTrue(ch["stacked"])
        self.assertTrue(ch["opts"]["isStacked"])

    def test_headline_and_override_cell_are_live_formulas(self):
        s = self.build(feed_rows(28))
        cells = self.js(f"{s}.sheets['Budget Pacing'].cells")
        top = 5  # first block
        self.assertIn("We have spent", cells[f"{top + 3},1"]["f"])
        self.assertEqual(cells[f"{top + 2},4"]["f"], f"=IF(ISNUMBER(C{top + 2}),C{top + 2},B{top + 2})")
        self.assertEqual(cells[f"{top + 2},6"]["v"], 28)
        self.assertEqual(cells[f"{top + 5},1"]["nf"], "@")      # day labels stay text -> discrete axis
        self.assertEqual(cells[f"{top + 5},2"]["nf"], "$#,##0")   # no decimals: the axis follows the cell format

    def test_rebuild_edits_charts_in_place_and_keeps_typed_overrides(self):
        s = self.build(feed_rows(28))
        first_id = self.js(f"{s}.sheets['Budget Pacing'].charts[0].id")
        self.ctx.eval(f"{s}.sheets['Budget Pacing'].getRange(7, 3).setValue(85000);")
        self.ctx.eval(f"{s}.sheets['Budget Pacing'].getRange(2, 2).setValue('2026-09-01');")
        self.ctx.eval(f"buildPacingTabs_({s});")            # the daily rebuild
        self.assertEqual(self.js(f"{s}.sheets['Budget Pacing'].charts.length"), 1)   # not duplicated
        self.assertEqual(self.js(f"{s}.sheets['Budget Pacing'].charts[0].id"), first_id)   # identity kept
        self.assertEqual(self.js(f"{s}.sheets['Budget Pacing'].cells['7,3'].v"), 85000)    # override survived
        self.assertEqual(self.js(f"{s}.sheets['Budget Pacing'].cells['2,2'].v"), "2026-09-01")

    def test_a_month_override_that_is_not_in_the_feed_is_ignored_and_says_so(self):
        s = self.build(feed_rows(28))
        self.ctx.eval(f"{s}.sheets['Budget Pacing'].getRange(2, 2).setValue('2027-03-01');")
        self.ctx.eval(f"buildPacingTabs_({s});")
        self.assertIn("ignored", self.js(f"{s}.sheets['Budget Pacing'].cells['3,1'].v"))
        self.assertEqual(self.js(f"{s}.sheets['Budget Pacing'].cells['2,4'].v"), "September 2026")

    def test_a_chart_the_run_no_longer_produces_is_pruned_but_foreign_charts_are_not(self):
        s = self.build(feed_rows(28))
        self.ctx.eval(f"""
          var sh = {s}.sheets['Budget Pacing'];
          sh.insertChart(chartOf({{opts: {{title: 'Old Unit — Budget Pacing'}}, ranges: [], stacked: true}}));
          sh.insertChart(chartOf({{opts: {{title: 'Someone typed this'}}, ranges: [], stacked: false}}));
          buildPacingTabs_({s});""")
        titles = sorted(self.js(f"{s}.sheets['Budget Pacing'].charts.map(function (c) {{ return c.opts.title; }})"))
        self.assertEqual(titles, ["Sephora US — Budget Pacing", "Someone typed this"])

    def test_actuals_through_is_shown_so_a_stale_feed_cannot_look_current(self):
        s = self.build(feed_rows(28))
        self.assertEqual(self.js(f"{s}.sheets['Budget Pacing'].cells['2,5'].v"), "Actuals through")
        self.assertEqual(self.js(f"{s}.sheets['Budget Pacing'].cells['2,6'].v"), "2026-09-28")
        s2 = self.build(feed_rows(0), name="s2")           # nothing actual yet
        self.assertEqual(self.js(f"{s2}.sheets['Budget Pacing'].cells['2,6'].v"), "none yet")

    def test_a_failure_is_written_into_the_tab_and_does_not_throw(self):
        self.ctx.eval("var bad = makeSpreadsheet('budget pacing @ 99', [['date'], ['2026-09-01']]);")
        self.ctx.eval("buildPacingTabs_(bad);")                    # must not raise
        msg = self.js("bad.sheets['Budget Pacing'].cells['3,1'].v")
        self.assertTrue(msg.startswith("⚠ Build failed"), msg)

    def test_disabled_until_a_card_id_is_set(self):
        ctx = MiniRacer(); ctx.eval(with_id(GS, "PACING_CARD_ID", 0)); ctx.eval(PRELUDE)
        ctx.eval("var s0 = makeSpreadsheet('budget pacing @ 0', [['date']]); buildPacingTabs_(s0);")
        self.assertEqual(json.loads(ctx.eval("JSON.stringify(Object.keys(s0.sheets))")), ["budget pacing @ 0"])


SALES_COLS = ["date", "month_start", "new_customer_gross_sales", "returning_customer_gross_sales",
              "gross_sales", "new_customers", "spend_meta", "spend_google", "spend_tiktok",
              "spend_prospecting", "spend_mixed", "spend_brand", "spend_nonbrand"]


def sales_rows(days=6, month="2026-10-01", tiktok=None, google_gap_on_last=False):
    rows = []
    for d in range(1, days + 1):
        iso = f"{month[:8]}{d:02d}"
        meta, google = 1500.0 + d, 1800.0 + d
        last_gap = google_gap_on_last and d == days
        rows.append([iso, month, 6000.0 + d, 24000.0 + d, 30000.0 + 2 * d, 80 + d,
                     meta, "" if last_gap else google, tiktok if tiktok is not None else "",
                     700.0, 800.0, "" if last_gap else 1300.0, "" if last_gap else 500.0])
    return rows


class SalesTab(unittest.TestCase):
    TAB = "Gross Sales vs Spend"

    @classmethod
    def setUpClass(cls):
        cls.ctx = MiniRacer()
        cls.ctx.eval(with_id(GS, "PACING_CARD_ID", 99))
        cls.ctx.eval(with_id(SALES_GS, "SALES_CARD_ID", 98))
        cls.ctx.eval(PRELUDE)

    def js(self, expr):
        return json.loads(self.ctx.eval(f"JSON.stringify({expr})"))

    def build(self, rows, name="v"):
        self.ctx.eval(f"var {name} = makeSpreadsheet('dtc sales vs spend @ 98', {json.dumps([SALES_COLS] + rows)});")
        self.ctx.eval(f"buildSalesTab_({name});")
        return name

    def charts(self, v):
        return {c["opts"]["title"]: c for c in self.js(f"{v}.sheets['{self.TAB}'].charts")}

    @staticmethod
    def series(chart):
        return [(s["targetAxisIndex"], s["color"])
                for _, s in sorted(chart["opts"]["series"].items(), key=lambda kv: int(kv[0]))]

    def test_two_charts_with_the_docs_titles_both_stacked(self):
        ch = self.charts(self.build(sales_rows()))
        self.assertEqual(set(ch), {"Gross Sales vs. paid spend", "Spend by type vs. new customers"})
        for c in ch.values():
            self.assertTrue(c["stacked"])
            self.assertTrue(c["opts"]["isStacked"])

    def test_sales_on_the_left_axis_spend_on_the_right_in_the_docs_colours(self):
        ch = self.charts(self.build(sales_rows()))
        self.assertEqual(self.series(ch["Gross Sales vs. paid spend"]),     # TikTok is blank all month: dropped
                         [(0, "#D98C00"), (0, "#1CB07A"), (1, "#172A7B"), (1, "#3C78D8")])
        self.assertEqual(self.series(ch["Spend by type vs. new customers"]),
                         [(0, "#908B82"), (1, "#EB6835"), (1, "#4B3AA7"), (1, "#3C78D8"), (1, "#9DC0EF")])

    def test_tiktok_spend_joins_the_right_axis_once_it_has_spend(self):
        ch = self.charts(self.build(sales_rows(tiktok=120.0)))
        self.assertEqual(self.series(ch["Gross Sales vs. paid spend"])[-1], (1, "#A4C2F4"))
        self.assertEqual(len(self.series(ch["Gross Sales vs. paid spend"])), 5)

    def test_the_nice_maximum_reproduces_the_docs_own_axes(self):
        for value, want in ((54545, 60000), (4540, 5000), (133, 160), (85257, 100000), (0, 4)):
            self.assertEqual(self.js(f"salesNiceMax_({value}, 4)"), want, value)

    def test_both_axes_get_a_maximum_and_the_same_gridline_count(self):
        ch = self.charts(self.build(sales_rows()))["Gross Sales vs. paid spend"]
        v = ch["opts"]["vAxes"]
        self.assertEqual(v["0"]["viewWindow"], {"min": 0, "max": 32000})       # tallest sales stack ~30,012
        self.assertEqual(v["1"]["viewWindow"], {"min": 0, "max": 4000})        # tallest spend stack ~3,312
        self.assertEqual(v["0"]["gridlines"], {"count": 5})
        self.assertEqual(v["1"]["gridlines"], {"count": 5})
        self.assertEqual((v["0"]["title"], v["1"]["title"]), ("Gross Sales", "Paid spend"))

    def test_an_axis_with_no_series_is_not_configured(self):
        rows = sales_rows()
        for r in rows:
            r[6] = r[7] = r[8] = r[9] = r[10] = r[11] = r[12] = ""          # no spend at all
        ch = self.charts(self.build(rows))["Gross Sales vs. paid spend"]
        self.assertEqual(sorted(ch["opts"]["vAxes"]), ["0"])

    def test_day_labels_read_like_the_docs_and_stay_text(self):
        v = self.build(sales_rows())
        cells = self.js(f"{v}.sheets['{self.TAB}'].cells")
        top = 5
        self.assertEqual(cells[f"{top + 4},1"]["v"], "Oct 1")
        self.assertEqual(cells[f"{top + 9},1"]["v"], "Oct 6")
        self.assertEqual(cells[f"{top + 4},1"]["nf"], "@")             # text, so the axis stays discrete

    def test_money_columns_are_dollars_and_customers_a_count(self):
        v = self.build(sales_rows())
        cells = self.js(f"{v}.sheets['{self.TAB}'].cells")
        self.assertEqual(cells["9,2"]["nf"], "$#,##0")                  # block 1: sales
        self.assertEqual(cells["47,2"]["nf"], "#,##0")                  # block 2: new customers
        self.assertEqual(cells["47,3"]["nf"], "$#,##0")                 # block 2: spend

    def test_month_to_date_has_only_the_days_in_the_feed(self):
        v = self.build(sales_rows(days=6))
        cells = self.js(f"{v}.sheets['{self.TAB}'].cells")
        self.assertNotIn("15,1", cells)                                  # no seventh day in block 1
        chart = self.charts(v)["Gross Sales vs. paid spend"]
        self.assertEqual(chart["ranges"][0][2], 1 + 6)                   # header + 6 days
        self.assertEqual(chart["pos"], [5, 1 + 4 + 2])                   # beside its own table
        self.assertEqual(cells["2,6"]["v"], "2026-10-06")                # data through

    def test_a_platform_that_has_not_synced_is_a_gap_not_a_zero(self):
        v = self.build(sales_rows(days=3, google_gap_on_last=True))
        cells = self.js(f"{v}.sheets['{self.TAB}'].cells")
        self.assertEqual(cells["11,5"]["v"], "")                         # Google on day 3: blank
        self.assertIsInstance(cells["11,4"]["v"], (int, float))          # Meta on day 3: a number

    def test_summaries_are_live_formulas_over_each_charts_own_table(self):
        v = self.build(sales_rows())
        cells = self.js(f"{v}.sheets['{self.TAB}'].cells")
        f1, f2 = cells["6,1"]["f"], cells["44,1"]["f"]
        self.assertTrue(f1.startswith('="Month to date: "&TEXT(SUM(B9:C14),"$#,##0")'), f1)
        self.assertIn("from new customers", f1)
        self.assertIn("SUM(D9:E14)", f1)                                 # Meta + Google, TikTok dropped
        self.assertTrue(f2.startswith('="Month to date: "&TEXT(SUM(B47:B52),"#,##0")'), f2)
        self.assertIn("SUM(C47:F52)", f2)

    def test_month_follows_the_data_and_an_unknown_override_is_ignored(self):
        v = self.build(sales_rows(days=3, month="2026-09-01") + sales_rows(days=6, month="2026-10-01"))
        self.assertEqual(self.js(f"{v}.sheets['{self.TAB}'].cells['2,4'].v"), "October 2026")
        self.ctx.eval(f"{v}.sheets['{self.TAB}'].getRange(2, 2).setValue('2026-09-01'); buildSalesTab_({v});")
        self.assertEqual(self.js(f"{v}.sheets['{self.TAB}'].cells['2,4'].v"), "September 2026")
        self.ctx.eval(f"{v}.sheets['{self.TAB}'].getRange(2, 2).setValue('2030-01-01'); buildSalesTab_({v});")
        self.assertIn("ignored", self.js(f"{v}.sheets['{self.TAB}'].cells['3,1'].v"))

    def test_rebuild_edits_in_place_without_duplicating_charts(self):
        v = self.build(sales_rows())
        ids = sorted(c["id"] for c in self.charts(v).values())
        self.ctx.eval(f"buildSalesTab_({v});")
        self.assertEqual(sorted(c["id"] for c in self.charts(v).values()), ids)

    def test_the_four_charts_of_the_earlier_version_are_removed_but_a_foreign_chart_is_not(self):
        v = self.build(sales_rows())
        self.ctx.eval(f"""
          var sh = {v}.sheets['{self.TAB}'];
          ['Gross Sales — new vs returning customers', 'Paid Spend — Meta, Google, TikTok', 'New Customers',
           'Paid Spend — by type', 'Someone typed this'].forEach(function (t) {{
            sh.insertChart(chartOf({{opts: {{title: t}}, ranges: [], stacked: true}})); }});
          buildSalesTab_({v});""")
        self.assertEqual(sorted(self.charts(v)),
                         ["Gross Sales vs. paid spend", "Someone typed this", "Spend by type vs. new customers"])

    def test_a_failure_is_written_into_the_tab_and_does_not_throw(self):
        self.ctx.eval("var bad = makeSpreadsheet('dtc sales vs spend @ 98', [['date'], ['2026-10-01']]); buildSalesTab_(bad);")
        self.assertTrue(self.js(f"bad.sheets['{self.TAB}'].cells['3,1'].v").startswith("⚠ Build failed"))

    def test_without_the_pacing_file_it_says_so_plainly(self):
        ctx = MiniRacer(); ctx.eval(with_id(SALES_GS, "SALES_CARD_ID", 98)); ctx.eval(PRELUDE)
        ctx.eval(f"var w = makeSpreadsheet('dtc sales vs spend @ 98', {json.dumps([SALES_COLS] + sales_rows())}); buildSalesTab_(w);")
        msg = json.loads(ctx.eval(f"JSON.stringify(w.sheets['{self.TAB}'].cells['3,1'].v)"))
        self.assertIn("build_pacing_tabs.gs", msg)

    def test_disabled_until_a_card_id_is_set(self):
        ctx = MiniRacer(); ctx.eval(with_id(GS, "PACING_CARD_ID", 0)); ctx.eval(with_id(SALES_GS, "SALES_CARD_ID", 0)); ctx.eval(PRELUDE)
        ctx.eval("var s0 = makeSpreadsheet('dtc sales vs spend @ 0', [['date']]); buildSalesTab_(s0);")
        self.assertEqual(json.loads(ctx.eval("JSON.stringify(Object.keys(s0.sheets))")), ["dtc sales vs spend @ 0"])


class MetabaseRefresh(unittest.TestCase):
    """refreshCardFeed_ is shared by both cards; the order of operations is the whole point."""

    def setUp(self):
        self.ctx = MiniRacer()
        self.ctx.eval(GS)
        self.ctx.eval(PRELUDE)
        self.ctx.eval("CURRENT_SS = makeSpreadsheet('x', [['a']]);")

    def test_date_formats_are_set_before_values_are_written(self):
        csv = "date,month_start,spend\n2026-10-01,2026-10-01,5\n2026-10-02,2026-10-01,6"
        self.ctx.eval(f"UrlFetchApp.next = fakeResponse(200, {json.dumps(csv)});")
        n = json.loads(self.ctx.eval("JSON.stringify(refreshCardFeed_(7, 'feed7', ['date', 'month_start']))"))
        self.assertEqual(n, 2)
        log = json.loads(self.ctx.eval("JSON.stringify(CURRENT_SS.sheets['feed7'].log)"))
        self.assertLess(log.index("fmt"), log.index("values"), log)
        self.assertEqual(json.loads(self.ctx.eval("JSON.stringify(CURRENT_SS.sheets['feed7'].cells['2,1'].nf)")), "yyyy-mm-dd")
        call = json.loads(self.ctx.eval("JSON.stringify(UrlFetchApp.calls[0])"))
        self.assertEqual(call["url"], "https://mb.example/api/card/7/query/csv")
        self.assertEqual(call["opts"]["headers"]["x-api-key"], "KEY")

    def test_an_auth_failure_names_the_likely_cause(self):
        self.ctx.eval("UrlFetchApp.next = fakeResponse(401, 'nope');")
        with self.assertRaises(Exception) as cm:
            self.ctx.eval("refreshCardFeed_(7, 'feed7', ['date'])")
        self.assertIn("401", str(cm.exception))
        self.assertIn("API key", str(cm.exception))

    def test_an_empty_card_is_an_error_not_a_blank_tab(self):
        self.ctx.eval("UrlFetchApp.next = fakeResponse(200, '');")
        with self.assertRaises(Exception):
            self.ctx.eval("refreshCardFeed_(7, 'feed7', ['date'])")

    def test_both_cards_are_off_until_configured(self):
        ctx = MiniRacer(); ctx.eval(with_id(GS, "PACING_CARD_ID", 0)); ctx.eval(with_id(SALES_GS, "SALES_CARD_ID", 0)); ctx.eval(PRELUDE)
        self.assertEqual(json.loads(ctx.eval("JSON.stringify([refreshPacingFeed_(), refreshSalesFeed_()])")), [0, 0])



if __name__ == "__main__":
    unittest.main(verbosity=2)
