#!/usr/bin/env python3
"""
Tests for scripts/build_pacing_tabs.gs, run in a real V8 with a mock Sheets API.

    pip install py-mini-racer
    python3 scripts/test_pacing_tabs.py

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
import json, pathlib, sys, unittest

try:
    from py_mini_racer import MiniRacer
except ImportError:
    print("SKIP: py-mini-racer is not installed (pip install py-mini-racer)")
    sys.exit(0)

ROOT = pathlib.Path(__file__).resolve().parent.parent
GS = (ROOT / "scripts" / "build_pacing_tabs.gs").read_text()

PRELUDE = r"""
var Logger = { log: function () {} };
var Utilities = { formatDate: function (d) { return d.toISOString().slice(0, 10); } };

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
  var sh = { name: name, cells: {}, charts: [] };
  var key = function (r, c) { return r + ',' + c; };
  var cell = function (r, c) { return sh.cells[key(r, c)] || (sh.cells[key(r, c)] = { v: null, f: null, nf: null }); };
  sh.getRange = function (r, c, nr, nc) {
    nr = nr || 1; nc = nc || 1;
    var rng = { desc: [r, c, nr, nc] };
    rng.setValue = function (v) { var x = cell(r, c); x.v = v; x.f = null; return rng; };
    rng.setValues = function (vals) {
      for (var i = 0; i < nr; i++) for (var j = 0; j < nc; j++) { var x = cell(r + i, c + j); x.v = vals[i][j]; x.f = null; }
      return rng;
    };
    rng.setFormula = function (f) { var x = cell(r, c); x.f = f; x.v = null; return rng; };
    rng.setNumberFormat = function (nf) { for (var i = 0; i < nr; i++) for (var j = 0; j < nc; j++) cell(r + i, c + j).nf = nf; return rng; };
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
        cls.ctx.eval(GS.replace("var PACING_CARD_ID = 0;", "var PACING_CARD_ID = 99;"))
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

    def test_pacing_columns_pair_actual_and_forecast_in_stack_order(self):
        rows = self.js(f"pacingParseFeed_({json.dumps([COLS] + feed_rows(28))}, 'UTC')")
        m = self.js(f"pacingUnitModel_({json.dumps(rows)}, 'sephora_us', '2026-09-01', 'pacing')")
        heads = [c["header"] for c in m["columns"]]
        self.assertEqual(heads, ["Meta US Traffic (actual)", "Meta US Traffic",
                                 "Meta US Collab (actual)", "Meta US Collab",
                                 "TikTok US Traffic (actual)", "TikTok US Traffic"])  # New US Collab is all zero: dropped
        self.assertEqual(len(m["matrix"]), 30)
        # day 1 is an actual day: the actual cell holds the value, the forecast cell is blank
        self.assertEqual(m["matrix"][0][:3], ["9/1", 1801.0, ""])
        # day 29 is a forecast day: the reverse
        self.assertEqual(m["matrix"][28][:3], ["9/29", "", 1800.0])

    def test_only_one_of_each_actual_forecast_pair_is_ever_filled(self):
        rows = self.js(f"pacingParseFeed_({json.dumps([COLS] + feed_rows(10))}, 'UTC')")
        m = self.js(f"pacingUnitModel_({json.dumps(rows)}, 'sephora_us', '2026-09-01', 'pacing')")
        for line in m["matrix"]:
            for i in range(1, len(line), 2):
                self.assertFalse(line[i] != "" and line[i + 1] != "", line)

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

    def test_chart_series_colours_and_legend_visibility(self):
        s = self.build(feed_rows(28))
        ch = self.js(f"{s}.sheets['Budget Pacing'].charts[0]")
        self.assertEqual(ch["opts"]["title"], "Sephora US — Budget Pacing")     # no month: stable identity
        ser = ch["opts"]["series"]
        self.assertEqual(len(ser), 6)
        self.assertEqual([ser[str(i)]["color"] for i in range(6)],
                         ["#B7B7B7", "#A4C2F4", "#999999", "#3C78D8", "#434343", "#FF9900"])
        self.assertEqual([ser[str(i)]["visibleInLegend"] for i in range(6)],
                         [False, True, False, True, False, True])
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
        ctx = MiniRacer(); ctx.eval(GS); ctx.eval(PRELUDE)         # PACING_CARD_ID left at 0
        ctx.eval("var s0 = makeSpreadsheet('budget pacing @ 0', [['date']]); buildPacingTabs_(s0);")
        self.assertEqual(json.loads(ctx.eval("JSON.stringify(Object.keys(s0.sheets))")), ["budget pacing @ 0"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
