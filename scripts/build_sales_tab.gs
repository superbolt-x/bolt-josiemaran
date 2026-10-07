/**
 * Josie Maran — Gross Sales vs Spend
 * RUN: paste as a THIRD file next to build_gsheet.gs and build_pacing_tabs.gs, set
 * SALES_CARD_ID, Save, then Run ▸ refreshAndRebuild. build_gsheet.gs calls into this
 * file if it is present and skips it if not.
 *
 * NEEDS build_pacing_tabs.gs: it shares that file's small date helpers and its
 * Metabase refresh (pacingIso_, pacingMonthOf_, refreshCardFeed_ ...). Apps Script
 * files share one namespace, so there is nothing to import, but both must be pasted.
 *
 * ── WHAT IT BUILDS ──────────────────────────────────────────────────────────
 * One script-owned tab, "Gross Sales vs Spend", month to date, with the weekly doc's
 * two Shopify charts, one chart each, drawn as the doc draws them:
 *
 *   Gross Sales vs. paid spend       per day, a stack of new + returning customer gross
 *                                    sales (left axis) beside a stack of Meta + Google +
 *                                    TikTok spend (right axis)
 *   Spend by type vs. new customers  per day, a column of new customers (left axis) beside
 *                                    a stack of Prospecting / Mixed / Brand / Nonbrand
 *                                    spend (right axis)
 *
 * ── HOW THE PAIRS ARE DRAWN ─────────────────────────────────────────────────
 * Nothing clever. In a STACKED column chart, series assigned to different axes are
 * drawn as separate stacks SIDE BY SIDE inside each day, with the label centred under
 * the pair. The table is one row per day; some columns are on the left axis, the rest
 * on the right. (An earlier version of this file split each doc chart into two charts
 * on the belief that Sheets could not do this. That belief had never been tested. A
 * throwaway spike on the live sheet, rendered and compared with the doc, showed
 * the plain layout already gives the doc's chart.)
 *
 * What the spike also showed, and why the axis options below are set the way they are:
 *  - Explicit axis ranges and a gridline count ARE honoured. Each axis is therefore
 *    given a "nice" maximum so both have the same five gridlines, as the doc's do
 *    ($0/$15K/$30K/$45K/$60K against $0/$1.25K/$2.5K/$3.75K/$5K). Left to
 *    themselves the two axes pick unrelated scales and the gridlines do not line up.
 *  - The axis LABELS follow the cells' number format, not the vAxes format option, so
 *    customers are a count and the rest are dollars with no decimals.
 *  - A series that is blank all month is dropped by Google itself (TikTok today).
 *
 * ── MONTH TO DATE, DECIDED RULE ─────────────────────────────────────────────
 * The doc's version showed a hand-picked 10 days (9/18-9/27) split "Pre / Post Spend
 * Adjustment" around one spend decision on 9/23. That was a one-off, so this shows the
 * month so far, through the last complete day. The month follows the data, like the
 * pacing tabs: on the 1st it still shows the month that just closed. B2 overrides it.
 * There is deliberately no event-date feature: how this chart evolves is not known yet.
 * At month end that is 31 pairs, so the charts are 1,100px wide.
 *
 * ── DEFINITIONS (and why they differ from the DTC WoW report) ───────────────
 *  - Spend is what the weekly doc counts: Meta, Google and, when it launches, TikTok
 *    Web. Lead Gen is INCLUDED, as Prospecting. The DTC WoW report's "Paid DTC
 *    Overall" leaves Lead Gen out, so the two will not agree on Meta spend.
 *  - TikTok GMV Max is EXCLUDED: its revenue is TikTok Shop GMV, which never reaches
 *    Shopify, and these charts compare spend with Shopify sales.
 *  - "TikTok spend" has no sampled colour (there are no TikTok bars in the doc chart
 *    to sample); it uses the light blue the pacing charts use for Meta prospecting.
 *  - Chart titles carry no month, so a chart is edited in place and keeps its ID,
 *    which keeps a Doc or Slides link to it alive.
 */

var SALES_CARD_ID = 57544;   // "JM – DTC Sales vs Spend", built from metabase/03_dtc_sales_vs_spend.sql.
                             // 0 = not wired up: this tab is skipped, nothing else is affected.

function salesFeedName_() { return 'dtc sales vs spend @ ' + SALES_CARD_ID; }

var SALES_TAB = 'Gross Sales vs Spend';
var SALES_FIRST_BLOCK_ROW = 5;
var SALES_BLOCK_ROWS      = 38;
var SALES_CHART           = { width: 1100, height: 420 };
var SALES_NOTE_COLOR      = '#66756f';
var SALES_GRIDLINES       = 5;     // same count on both axes, so their gridlines line up
var SALES_REQUIRED_COLS   = ['date', 'month_start', 'new_customer_gross_sales',
  'returning_customer_gross_sales', 'new_customers', 'spend_meta', 'spend_google', 'spend_tiktok',
  'spend_prospecting', 'spend_mixed', 'spend_brand', 'spend_nonbrand'];

// Colours are sampled from the doc's rendered charts. `left` series use the left axis and
// `right` the right axis; stack order is bottom to top within each.
var SALES_CHARTS = [
  { id: 'sales', title: 'Gross Sales vs. paid spend',
    leftTitle: 'Gross Sales', rightTitle: 'Paid spend',
    left: [
      { col: 'new_customer_gross_sales',       label: 'New-customer gross sales',       color: '#D98C00', fmt: '$#,##0' },
      { col: 'returning_customer_gross_sales', label: 'Returning-customer gross sales', color: '#1CB07A', fmt: '$#,##0' }],
    right: [
      { col: 'spend_meta',   label: 'Meta spend',   color: '#172A7B', fmt: '$#,##0' },
      { col: 'spend_google', label: 'Google spend', color: '#3C78D8', fmt: '$#,##0' },
      { col: 'spend_tiktok', label: 'TikTok spend', color: '#A4C2F4', fmt: '$#,##0' }] },
  { id: 'type', title: 'Spend by type vs. new customers',
    leftTitle: 'New customers', rightTitle: 'Paid spend',
    left: [
      { col: 'new_customers', label: 'New customers', color: '#908B82', fmt: '#,##0' }],
    right: [
      { col: 'spend_prospecting', label: 'Prospecting',                        color: '#EB6835', fmt: '$#,##0' },
      { col: 'spend_mixed',       label: 'Mixed (retargeting + reactivation)', color: '#4B3AA7', fmt: '$#,##0' },
      { col: 'spend_brand',       label: 'Brand',                              color: '#3C78D8', fmt: '$#,##0' },
      { col: 'spend_nonbrand',    label: 'Nonbrand',                           color: '#9DC0EF', fmt: '$#,##0' }] }
];

// Charts an earlier version of this file made, as four charts. They keep their place on the
// tab after it is wiped, so they are removed by title if they are still there.
var SALES_RETIRED_TITLES = ['Gross Sales — new vs returning customers', 'Paid Spend — Meta, Google, TikTok',
                            'New Customers', 'Paid Spend — by type'];

var SALES_MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

/* ════════════════════════════════════════════════════════════════════════════
   PURE LOGIC
   ════════════════════════════════════════════════════════════════════════════ */

/** '2026-09-18' -> 'Sep 18', the label the doc's Shopify charts use. */
function salesLabel_(iso) { return SALES_MONTHS[Number(iso.slice(5, 7)) - 1] + ' ' + Number(iso.slice(8, 10)); }

/** Feed values -> row objects, columns found by NAME. Blank stays null, never 0. */
function salesParseFeed_(values, tz) {
  var header = values[0], idx = {};
  SALES_REQUIRED_COLS.forEach(function (c) {
    idx[c] = header.indexOf(c);
    if (idx[c] < 0) {
      throw new Error('Sales feed has no "' + c + '" column. Re-paste the card from ' +
                      'metabase/03_dtc_sales_vs_spend.sql and refresh.');
    }
  });
  var out = [];
  for (var r = 1; r < values.length; r++) {
    var row = values[r];
    if (row[idx.date] === '') continue;
    var o = { date: pacingIso_(row[idx.date], tz), monthStart: pacingIso_(row[idx.month_start], tz) };
    SALES_REQUIRED_COLS.forEach(function (c) {
      if (c !== 'date' && c !== 'month_start') o[c] = pacingNum_(row[idx[c]]);
    });
    out.push(o);
  }
  return out;
}

/** The month of the latest complete day, unless a valid override is typed. */
function salesPickMonth_(rows, overrideIso) {
  var months = {}, latest = '';
  rows.forEach(function (r) { months[r.monthStart] = true; if (r.date > latest) latest = r.date; });
  var month = latest ? pacingMonthOf_(latest) : '';
  var ignored = false;
  if (overrideIso) {
    var o = pacingMonthOf_(overrideIso);
    if (months[o]) month = o; else ignored = true;
  }
  return { month: month, latest: latest, overrideIgnored: ignored };
}

/**
 * The top of an axis: the smallest "nice" tick step that fits the tallest stack, times the
 * number of intervals. 54,545 with 4 intervals gives 60,000 (ticks of 15,000), and 4,540
 * gives 5,000 (ticks of 1,250), which are the doc's own axes. 3% headroom keeps the
 * tallest bar from touching the top.
 */
function salesNiceMax_(value, intervals) {
  if (!(value > 0)) return intervals;
  var step = value * 1.03 / intervals;
  var mag = Math.pow(10, Math.floor(Math.log(step) / Math.LN10));
  var nice = [1, 1.25, 1.5, 2, 2.5, 3, 4, 5, 6, 8, 10];
  for (var i = 0; i < nice.length; i++) {
    if (nice[i] * mag >= step) return nice[i] * mag * intervals;
  }
  return 10 * mag * intervals;
}

/**
 * One chart's table and axes: the days of the month that have data, the series that carry
 * any value (a series blank or zero all month is dropped), and a maximum for each axis from
 * the tallest daily stack on that side.
 */
function salesChartModel_(rows, monthIso, cfg) {
  var days = rows.filter(function (r) { return r.monthStart === monthIso; })
                 .sort(function (a, b) { return a.date < b.date ? -1 : 1; });
  function live(list) {
    return list.filter(function (s) {
      return days.some(function (r) { return r[s.col] !== null && r[s.col] !== 0; });
    });
  }
  var left = live(cfg.left), right = live(cfg.right);
  var columns = left.map(function (s) { return { s: s, axis: 0 }; })
                    .concat(right.map(function (s) { return { s: s, axis: 1 }; }));

  var matrix = days.map(function (r) {
    return [salesLabel_(r.date)].concat(columns.map(function (c) {
      return r[c.s.col] === null ? '' : r[c.s.col];
    }));
  });

  function tallest(list) {
    var best = 0;
    days.forEach(function (r) {
      var sum = 0;
      list.forEach(function (s) { if (r[s.col] !== null) sum += r[s.col]; });
      if (sum > best) best = sum;
    });
    return best;
  }
  return { cfg: cfg, columns: columns, matrix: matrix, nLeft: left.length, nRight: right.length,
           leftMax: salesNiceMax_(tallest(left), SALES_GRIDLINES - 1),
           rightMax: salesNiceMax_(tallest(right), SALES_GRIDLINES - 1),
           empty: days.length === 0 || columns.length === 0 };
}

/** The chart's options, as plain data. Only the axes that have a series are configured. */
function salesChartOptions_(model) {
  var series = {}, vAxes = {};
  model.columns.forEach(function (c, i) { series[i] = { color: c.s.color, targetAxisIndex: c.axis }; });
  if (model.nLeft) {
    vAxes[0] = { title: model.cfg.leftTitle, viewWindow: { min: 0, max: model.leftMax }, gridlines: { count: SALES_GRIDLINES } };
  }
  if (model.nRight) {
    vAxes[1] = { title: model.cfg.rightTitle, viewWindow: { min: 0, max: model.rightMax }, gridlines: { count: SALES_GRIDLINES } };
  }
  return { title: model.cfg.title, isStacked: true, series: series, vAxes: vAxes,
           legend: { position: 'bottom' }, width: SALES_CHART.width, height: SALES_CHART.height };
}

/* ════════════════════════════════════════════════════════════════════════════
   SHEET WRITING
   ════════════════════════════════════════════════════════════════════════════ */

/** Called from buildReport(). A failure is written into the tab, never thrown. */
function buildSalesTab_(ss) {
  if (!SALES_CARD_ID) { Logger.log('Gross Sales vs Spend skipped: SALES_CARD_ID is not set.'); return; }
  var sh = ss.getSheetByName(SALES_TAB) || ss.insertSheet(SALES_TAB);
  try {
    if (typeof pacingIso_ !== 'function' || typeof refreshCardFeed_ !== 'function') {
      throw new Error('build_sales_tab.gs needs build_pacing_tabs.gs in the same project.');
    }
    var feed = ss.getSheetByName(salesFeedName_());
    if (!feed || feed.getLastRow() < 2) {
      throw new Error('Feed tab "' + salesFeedName_() + '" is missing or empty. Run refreshAndRebuild ' +
                      'or point the Metabase extension at question ' + SALES_CARD_ID + '.');
    }
    var tz = ss.getSpreadsheetTimeZone();
    var rows = salesParseFeed_(feed.getDataRange().getValues(), tz);
    if (!rows.length) throw new Error('The sales feed has no rows.');

    var keep = '';
    var m = sh.getRange(2, 2).getValue();
    if (m !== '' && m !== null) { var iso = pacingIso_(m, tz); if (/^\d{4}-\d{2}/.test(iso)) keep = iso.slice(0, 7) + '-01'; }
    sh.clear();
    sh.clearConditionalFormatRules();

    var pick = salesPickMonth_(rows, keep);
    sh.getRange(1, 1).setValue(SALES_TAB).setFontWeight('bold').setFontSize(14);
    sh.getRange(2, 1).setValue('Month override (optional, e.g. 2026-10-01)');
    sh.getRange(2, 2).setNumberFormat('@').setValue(keep);
    sh.getRange(2, 3).setValue('Showing');
    sh.getRange(2, 4).setValue(pacingMonthName_(pick.month)).setFontWeight('bold');
    sh.getRange(2, 5).setValue('Data through');
    sh.getRange(2, 6).setNumberFormat('@').setValue(pick.latest).setFontWeight('bold');
    sh.getRange(3, 1).setValue('Month to date, through the last complete day. Lead Gen counts as Prospecting; ' +
      'TikTok GMV Max is excluded (its revenue is TikTok Shop, not Shopify). A blank spend day means that platform has not synced yet.' +
      (pick.overrideIgnored ? '  (Month override ignored: that month is not in the feed.)' : ''))
      .setFontColor(SALES_NOTE_COLOR);

    // Charts a previous version made, as four, would otherwise sit on the tab beside the new ones.
    sh.getCharts().forEach(function (ch) {
      if (SALES_RETIRED_TITLES.indexOf(pacingChartTitle_(ch)) >= 0) sh.removeChart(ch);
    });

    SALES_CHARTS.forEach(function (cfg, i) {
      var top = SALES_FIRST_BLOCK_ROW + i * SALES_BLOCK_ROWS;
      var model = salesChartModel_(rows, pick.month, cfg);
      writeSalesBlock_(sh, top, model);
      if (!model.empty) upsertSalesChart_(sh, top, model);
    });
  } catch (e) {
    Logger.log('Gross Sales vs Spend failed: ' + e.message);
    sh.getRange(3, 1).setValue('⚠ Build failed: ' + e.message);
    ss.toast('Gross Sales vs Spend failed: ' + e.message, SALES_TAB, 15);
  }
}

function colLetterSales_(n) {
  var s = '';
  while (n > 0) { var m = (n - 1) % 26; s = String.fromCharCode(65 + m) + s; n = (n - m - 1) / 26; }
  return s;
}

function writeSalesBlock_(sh, top, model) {
  sh.getRange(top, 1).setValue(model.cfg.title).setFontWeight('bold').setFontSize(12);
  if (model.empty) {
    sh.getRange(top + 1, 1).setValue('No complete days with data this month yet.').setFontColor(SALES_NOTE_COLOR);
    return;
  }
  var nCols = 1 + model.columns.length, headerRow = top + 3, n = model.matrix.length;
  var first = headerRow + 1, last = headerRow + n;
  var leftEnd = colLetterSales_(1 + model.nLeft), rightStart = colLetterSales_(2 + model.nLeft);
  var rightEnd = colLetterSales_(nCols);

  // A live one-line summary: sales or customers on the left, spend on the right.
  var parts = [];
  if (model.nLeft) {
    var leftFmt = model.columns[0].s.fmt === '#,##0' ? '#,##0' : '$#,##0';
    var leftRng = 'B' + first + ':' + leftEnd + last;
    var leftWord = model.cfg.id === 'sales' ? ' gross sales' : ' new customers';
    var lead = '"Month to date: "&TEXT(SUM(' + leftRng + '),"' + leftFmt + '")&"' + leftWord;
    if (model.cfg.id === 'sales' && model.nLeft > 1) {
      lead += ' ("&TEXT(IFERROR(SUM(B' + first + ':B' + last + ')/SUM(' + leftRng + '),0),"0%")&" from new customers)';
    }
    parts.push(lead + '"');
  }
  if (model.nRight) {
    parts.push('"; "&TEXT(SUM(' + rightStart + first + ':' + rightEnd + last + '),"$#,##0")&" paid spend."');
  }
  sh.getRange(top + 1, 1).setFormula('=' + parts.join('&')).setFontWeight('bold');

  sh.getRange(headerRow, 1, 1, nCols)
    .setValues([['Date'].concat(model.columns.map(function (c) { return c.s.label; }))]).setFontWeight('bold');
  // Day labels as TEXT ('Oct 6'): a real date column makes the chart draw a continuous time
  // axis with thin bars, where the doc's charts are discrete.
  sh.getRange(first, 1, n, 1).setNumberFormat('@');
  sh.getRange(first, 1, n, nCols).setValues(model.matrix);
  // The axis labels follow each column's number format, so format by what it holds.
  model.columns.forEach(function (c, k) { sh.getRange(first, 2 + k, n, 1).setNumberFormat(c.s.fmt); });
}

function upsertSalesChart_(sh, top, model) {
  var headerRow = top + 3, nCols = 1 + model.columns.length;
  var range = sh.getRange(headerRow, 1, 1 + model.matrix.length, nCols);
  var opts = salesChartOptions_(model);

  var existing = sh.getCharts(), match = null;
  for (var i = 0; i < existing.length; i++) {
    if (pacingChartTitle_(existing[i]) === opts.title) { match = existing[i]; break; }
  }
  // setStacked() exists only on the column builder, and modify() returns a generic builder,
  // so the isStacked option is what keeps an EXISTING chart right; setStacked() just makes a
  // new one right.
  var b = match ? match.modify() : sh.newChart().asColumnChart().setStacked();
  if (match) b.clearRanges();
  b.addRange(range)
    .setNumHeaders(1)
    .setOption('isStacked', opts.isStacked)
    .setOption('title', opts.title)
    .setOption('series', opts.series)
    .setOption('vAxes', opts.vAxes)
    .setOption('legend', opts.legend)
    .setOption('width', opts.width)
    .setOption('height', opts.height)
    .setPosition(top, nCols + 2, 0, 0);
  if (match) sh.updateChart(b.build());
  else       sh.insertChart(b.build());
}

function refreshSalesFeed_() {
  if (!SALES_CARD_ID) return 0;
  return refreshCardFeed_(SALES_CARD_ID, salesFeedName_(), ['date', 'month_start']);
}
