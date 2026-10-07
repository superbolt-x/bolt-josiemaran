/**
 * Josie Maran — Gross Sales vs Spend
 * RUN: paste as a THIRD file next to build_gsheet.gs and build_pacing_tabs.gs, set
 * SALES_CARD_ID, Save, then Run ▸ refreshAndRebuild. build_gsheet.gs calls into this
 * file if it is present and skips it if not.
 *
 * NEEDS build_pacing_tabs.gs: it shares that file's small date helpers and its
 * Metabase refresh (pacingIso_, pacingLabel_, refreshCardFeed_ ...). Apps Script
 * files share one namespace, so there is nothing to import, but both must be pasted.
 *
 * ── WHAT IT BUILDS ──────────────────────────────────────────────────────────
 * One script-owned tab, "Gross Sales vs Spend", month to date, with four charts
 * that stand in for the two Shopify charts in the weekly doc:
 *
 *   doc: "Gross Sales vs. paid spend"            here: 1 Gross Sales (new vs returning)
 *                                                       2 Paid Spend (Meta / Google / TikTok)
 *   doc: "Spend by type vs. new customers"       here: 3 New Customers
 *                                                       4 Paid Spend (by type)
 *
 * ── WHY EACH DOC CHART BECOMES TWO ──────────────────────────────────────────
 * The doc draws sales and spend as PAIRS of stacked bars per day on two axes:
 * $60K of sales next to $5K of spend, each filling its own scale. Google Sheets has
 * no such chart: a combo chart cannot put two stacks side by side, and overlaying
 * them on two axes hides one behind the other. So each is split into two native
 * charts that share the same days, sales above and spend below, in the doc's exact
 * colours. Nothing is lost; what changes is that the eye compares across two charts
 * and not within one. Whether Google would render a hacked-together paired layout
 * well has not been tried, and is not worth betting a weekly deliverable on.
 *
 * ── MONTH TO DATE, DECIDED RULE ─────────────────────────────────────────────
 * The doc's version showed a hand-picked 10 days (9/18-9/27) split "Pre / Post Spend
 * Adjustment" around one spend decision on 9/23. That was a one-off, so this shows
 * the month so far instead, through the last complete day. The month follows the
 * data, like the pacing tabs: on the 1st it still shows the month that just closed.
 * An override in B2 shows another month. There is deliberately no event-date
 * feature: how this chart evolves is not known yet.
 *
 * ── DEFINITIONS (and why they differ from the DTC WoW report) ───────────────
 *  - Spend is what the weekly doc counts: Meta, Google and, when it launches, TikTok
 *    Web. Lead Gen is INCLUDED, as Prospecting. The DTC WoW report's "Paid DTC
 *    Overall" leaves Lead Gen out, so the two will not agree on Meta spend.
 *  - TikTok GMV Max is EXCLUDED: its revenue is TikTok Shop GMV, which never reaches
 *    Shopify, and these charts compare spend with Shopify sales.
 *  - A spend series that is zero or blank all month is dropped (TikTok today).
 *  - "TikTok spend" has no sampled colour (there are no TikTok bars in the doc chart
 *    to sample); it uses the light blue the pacing charts use for Meta prospecting.
 *  - Chart titles carry no month, for the same reason as the pacing tabs: a title is
 *    a chart's identity, and the chart is edited in place so a linked Doc survives.
 */

var SALES_CARD_ID = 0;   // Metabase question built from metabase/03_dtc_sales_vs_spend.sql.
                         // 0 = not wired up yet: this tab is skipped, nothing else is affected.

function salesFeedName_() { return 'dtc sales vs spend @ ' + SALES_CARD_ID; }

var SALES_TAB = 'Gross Sales vs Spend';
var SALES_FIRST_BLOCK_ROW = 5;
var SALES_BLOCK_ROWS      = 38;
var SALES_CHART           = { width: 780, height: 320 };
var SALES_NOTE_COLOR      = '#66756f';
var SALES_REQUIRED_COLS   = ['date', 'month_start', 'new_customer_gross_sales',
  'returning_customer_gross_sales', 'new_customers', 'spend_meta', 'spend_google', 'spend_tiktok',
  'spend_prospecting', 'spend_mixed', 'spend_brand', 'spend_nonbrand'];

// Colours are sampled from the doc's rendered charts. Stack order is bottom to top.
var SALES_BLOCKS = [
  { id: 'sales', title: 'Gross Sales — new vs returning customers', stacked: true, fmt: '$#,##0',
    summary: 'gross sales',
    series: [
      { col: 'new_customer_gross_sales',       label: 'New-customer gross sales',       color: '#D98C00' },
      { col: 'returning_customer_gross_sales', label: 'Returning-customer gross sales', color: '#1CB07A' }] },
  { id: 'spend', title: 'Paid Spend — Meta, Google, TikTok', stacked: true, fmt: '$#,##0',
    summary: 'paid spend',
    series: [
      { col: 'spend_meta',   label: 'Meta spend',   color: '#172A7B' },
      { col: 'spend_google', label: 'Google spend', color: '#3C78D8' },
      { col: 'spend_tiktok', label: 'TikTok spend', color: '#A4C2F4' }] },
  { id: 'newcust', title: 'New Customers', stacked: false, fmt: '#,##0', legend: 'none',
    summary: 'new customers',
    series: [ { col: 'new_customers', label: 'New customers', color: '#908B82' } ] },
  { id: 'type', title: 'Paid Spend — by type', stacked: true, fmt: '$#,##0',
    summary: 'paid spend',
    series: [
      { col: 'spend_prospecting', label: 'Prospecting',                      color: '#EB6835' },
      { col: 'spend_mixed',       label: 'Mixed (retargeting + reactivation)', color: '#4B3AA7' },
      { col: 'spend_brand',       label: 'Brand',                            color: '#3C78D8' },
      { col: 'spend_nonbrand',    label: 'Nonbrand',                         color: '#9DC0EF' }] }
];

/* ════════════════════════════════════════════════════════════════════════════
   PURE LOGIC
   ════════════════════════════════════════════════════════════════════════════ */

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
 * One chart's table: the days of the month that have data, and the series that
 * carry any value. A series that is blank or zero all month is dropped, so a
 * platform that has not launched cannot clutter the legend.
 */
function salesBlockModel_(rows, monthIso, block) {
  var days = rows.filter(function (r) { return r.monthStart === monthIso; })
                 .sort(function (a, b) { return a.date < b.date ? -1 : 1; });
  var series = block.series.filter(function (s) {
    return days.some(function (r) { return r[s.col] !== null && r[s.col] !== 0; });
  });
  var matrix = days.map(function (r) {
    return [pacingLabel_(r.date)].concat(series.map(function (s) {
      return r[s.col] === null ? '' : r[s.col];
    }));
  });
  return { block: block, series: series, matrix: matrix, empty: days.length === 0 || series.length === 0 };
}

function salesChartOptions_(model) {
  var series = {};
  model.series.forEach(function (s, i) { series[i] = { color: s.color }; });
  return { title: model.block.title, series: series, isStacked: model.block.stacked,
           legend: { position: model.block.legend || 'top' }, vAxis: { format: model.block.fmt },
           width: SALES_CHART.width, height: SALES_CHART.height };
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

    SALES_BLOCKS.forEach(function (block, i) {
      var top = SALES_FIRST_BLOCK_ROW + i * SALES_BLOCK_ROWS;
      var model = salesBlockModel_(rows, pick.month, block);
      writeSalesBlock_(sh, top, model);
      if (!model.empty) upsertSalesChart_(sh, top, model);
    });
  } catch (e) {
    Logger.log('Gross Sales vs Spend failed: ' + e.message);
    sh.getRange(3, 1).setValue('⚠ Build failed: ' + e.message);
    ss.toast('Gross Sales vs Spend failed: ' + e.message, SALES_TAB, 15);
  }
}

function writeSalesBlock_(sh, top, model) {
  sh.getRange(top, 1).setValue(model.block.title).setFontWeight('bold').setFontSize(12);
  if (model.empty) {
    sh.getRange(top + 1, 1).setValue('No complete days with data this month yet.').setFontColor(SALES_NOTE_COLOR);
    return;
  }
  var nCols = 1 + model.series.length, headerRow = top + 3, n = model.matrix.length;
  var first = headerRow + 1, last = headerRow + n;
  var totalFmt = model.block.fmt === '#,##0' ? '#,##0' : '$#,##0';

  var rng = 'B' + first + ':' + colLetterSales_(nCols) + last;
  var text = '="Month to date: "&TEXT(SUM(' + rng + '),"' + totalFmt + '")&" ' + model.block.summary;
  if (model.block.id === 'sales') {
    text += ', "&TEXT(IFERROR(SUM(B' + first + ':B' + last + ')/SUM(' + rng + '),0),"0%")&" from new customers';
  }
  sh.getRange(top + 1, 1).setFormula(text + '."').setFontWeight('bold');

  sh.getRange(headerRow, 1, 1, nCols)
    .setValues([['Date'].concat(model.series.map(function (s) { return s.label; }))]).setFontWeight('bold');
  // Day labels as TEXT ('10/6'): a real date column makes the chart draw a continuous
  // time axis with thin bars, where the doc's charts are discrete.
  sh.getRange(first, 1, n, 1).setNumberFormat('@');
  sh.getRange(first, 1, n, nCols).setValues(model.matrix);
  sh.getRange(first, 2, n, nCols - 1).setNumberFormat(model.block.fmt === '#,##0' ? '#,##0' : '$#,##0.00');
}

function colLetterSales_(n) {
  var s = '';
  while (n > 0) { var m = (n - 1) % 26; s = String.fromCharCode(65 + m) + s; n = (n - m - 1) / 26; }
  return s;
}

function upsertSalesChart_(sh, top, model) {
  var headerRow = top + 3, nCols = 1 + model.series.length;
  var range = sh.getRange(headerRow, 1, 1 + model.matrix.length, nCols);
  var opts = salesChartOptions_(model);

  var existing = sh.getCharts(), match = null;
  for (var i = 0; i < existing.length; i++) {
    if (pacingChartTitle_(existing[i]) === opts.title) { match = existing[i]; break; }
  }
  // setStacked() exists only on the column builder, and modify() returns a generic
  // builder, so the isStacked option is what keeps an EXISTING chart right; setStacked()
  // just makes a new stacked one right.
  var b = match ? match.modify()
        : (opts.isStacked ? sh.newChart().asColumnChart().setStacked() : sh.newChart().asColumnChart());
  if (match) b.clearRanges();
  b.addRange(range)
    .setNumHeaders(1)
    .setOption('isStacked', opts.isStacked)
    .setOption('title', opts.title)
    .setOption('series', opts.series)
    .setOption('legend', opts.legend)
    .setOption('vAxis', opts.vAxis)
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
