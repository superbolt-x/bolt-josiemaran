/**
 * Josie Maran — Automated Reporting
 * RUN: Extensions → Apps Script → paste → Save → Run ▸ buildReport
 * Idempotent. Never touches the feed tab, which the Metabase extension owns.
 *
 * ── LAYOUT MIRRORS THE DECK, NOT A GENERIC GRID ─────────────────────────────
 * Each slide carries a WoW table with metrics down the rows and exactly TWO
 * date columns plus % change, and a "Spend vs ROAS" chart. So that is what
 * this builds: one KPI block per segment, metrics as rows, 2 periods + delta,
 * and a real combo chart over the last 4 periods beside it.
 *
 * The feed supplies 7 weeks and 3 months. The KPI block reads the last 2 and
 * the chart the last 4 — the filtering happens here, not in the card, so
 * changing the report window never means editing SQL.
 *
 * ── PERIODS ARE HANDLED AS DATES, NEVER AS LABEL TEXT ───────────────────────
 * This is the one thing in this file worth reading twice.
 *
 * Google Sheets auto-parses anything date-shaped on write. A period label of
 * '2026-08' became the serial 46235, and '8/23/2026' likewise. So a formula
 * that rebuilt the lookup key from a header cell produced
 *   "DTC Segment|Paid DTC Overall|All|46235"
 * while the card emitted "...|2026-08" — no match, every metric silently blank.
 * That was the empty MTD tab.
 *
 * The fix: header cells read period_start (column F, a genuine date), and the
 * key is rebuilt with TEXT(...) in the same ISO shape the card emits. Coercion
 * is now harmless — the cell is *supposed* to be a date — and the header can be
 * number-formatted for the client (8/23/2026, Aug 2026) with no effect on
 * matching. Never point a lookup at column E; it is display text only.
 *
 * ── FOUR CONVERSION SOURCES, NONE INTERCHANGEABLE ───────────────────────────
 * Column G (read_metrics) says which family applies to a row:
 *   paid_*  Meta/Google own pixel, view-through window
 *   ga4_*   GA4 last-non-direct session attribution
 *   cs_*    Sephora, via catalog segment actions
 *   site_*  what Shopify booked
 * paid_roas and ga4_roas WILL disagree. The DTC slides show both. Never add them.
 */

var FEED     = 'feed @ 57484';
var FEED_REF = "'" + FEED + "'";
var COLS     = '$A:$AV';        // 48 columns
var PSTART   = '$F:$F';         // period_start — the date the lookups key on
var KEY      = '$H:$H';         // lookup_key
var VALID    = '$AS:$AS';       // data_valid
var FEEDBACK = '$AT:$AT';       // has_catalog_feedback

var KPI_PERIODS   = 2;          // the slide's WoW table
var CHART_PERIODS = 4;          // the slide's chart

// How a period is displayed, and how it is written into the lookup key. The
// key half MUST match the card's lookup_key exactly (gen_reporting_feed.py).
// `fmt` is a Sheets number format (lowercase m = month). `hfmt` is the ICU
// pattern Google Charts wants for the same thing — there, lowercase m means
// MINUTES, so the two cannot be shared.
var GRAIN = {
  week:  { fmt: 'm/d/yyyy', hfmt: 'M/d',      key: 'yyyy-mm-dd', noun: 'weeks',  col: 'Week'  },
  month: { fmt: 'mmm yyyy', hfmt: 'MMM yyyy', key: 'yyyy-mm',    noun: 'months', col: 'Month' },
  // Month-to-date: two windows of equal length, this month and last, both
  // running day 1 to the last complete day. Keyed on the month start, which is
  // why `grain` has to be in the lookup key — 'month' and 'mtd' both key on
  // yyyy-mm, and without it a MATCH would return whichever row came first.
  mtd:   { fmt: 'mmm yyyy', hfmt: 'MMM yyyy', key: 'yyyy-mm',    noun: 'months', col: 'Month' }
};

// Metric sets, one per slide shape. Order is the order on the slide.
var SHAPES = {
  dtc: {
    metrics: [
      ['Spend',      'spend',          '$#,##0'],
      ['CPM',        'cpm',            '$0.00'],
      ['CTR',        'ctr',            '0.00%'],
      ['Clicks',     'clicks',         '#,##0'],
      ['CPC',        'cpc',            '$0.00'],
      ['CVR',        'paid_cvr',       '0.00%'],
      ['Purchases',  'paid_purchases', '#,##0'],
      ['CPA',        'paid_cpa',       '$#,##0.00'],
      ['Revenue',    'paid_revenue',   '$#,##0'],
      ['ROAS',       'paid_roas',      '0.00'],
      ['GA4 ROAS',   'ga4_roas',       '0.00'],
      ['AOV',        'paid_aov',       '$#,##0.00']
    ],
    chart: [['Spend', 'spend', '$#,##0'], ['ROAS', 'paid_roas', '0.00']],
    flag: VALID, flagStyle: 'grey'
  },
  sephoraTraffic: {
    // Delivery only, on purpose. These campaigns emit no catalog-segment rows,
    // so there is no honest Sephora conversion figure to put on the slide.
    metrics: [
      ['Spend',  'spend',  '$#,##0'],
      ['CPM',    'cpm',    '$0.00'],
      ['CTR',    'ctr',    '0.00%'],
      ['Clicks', 'clicks', '#,##0'],
      ['CPC',    'cpc',    '$0.00']
    ],
    chart: [['Spend', 'spend', '$#,##0'], ['CPC', 'cpc', '$0.00']],
    flag: FEEDBACK, flagStyle: 'amber'
  },
  sephoraCollab: {
    metrics: [
      ['Spend',     'spend',        '$#,##0'],
      ['CPM',       'cpm',          '$0.00'],
      ['CTR',       'ctr',          '0.00%'],
      ['CPC',       'cpc',          '$0.00'],
      ['CVR',       'cs_cvr',       '0.00%'],
      ['Purchases', 'cs_purchases', '#,##0'],
      ['CPA',       'cs_cpa',       '$#,##0.00'],
      ['Revenue',   'cs_revenue',   '$#,##0'],
      ['ROAS',      'cs_roas',      '0.00'],
      ['AOV',       'cs_aov',       '$#,##0.00'],
      ['% in store','pct_instore',  '0.0%']
    ],
    chart: [['Spend', 'spend', '$#,##0'], ['ROAS', 'cs_roas', '0.00']],
    flag: FEEDBACK, flagStyle: 'amber'
  },
  site: {
    metrics: [
      ['Orders',        'site_orders',        '#,##0'],
      ['First orders',  'site_first_orders',  '#,##0'],
      ['New customers', 'site_new_customers', '#,##0'],
      ['Gross sales',   'site_gross_sales',   '$#,##0'],
      ['AOV',           'aov',                '$#,##0.00'],
      ['% new orders',  'pct_new',            '0.0%']
    ],
    chart: [['Gross sales', 'site_gross_sales', '$#,##0'], ['Orders', 'site_orders', '#,##0']],
    flag: VALID, flagStyle: 'grey'
  },
  ga4: {
    metrics: [
      ['Sessions',  'ga4_sessions',  '#,##0'],
      ['Purchases', 'ga4_purchases', '#,##0'],
      ['Revenue',   'ga4_revenue',   '$#,##0'],
      ['CVR',       'ga4_cvr',       '0.00%'],
      ['AOV',       'ga4_aov',       '$#,##0.00']
    ],
    chart: [['Revenue', 'ga4_revenue', '$#,##0'], ['Sessions', 'ga4_sessions', '#,##0']],
    flag: VALID, flagStyle: 'grey'
  }
};

// One entry per slide: [row_label, report_level, market].
var TABS = {
  'DTC WoW': { shape: 'dtc', grain: 'week', slides: [
    ['Paid DTC Overall', 'DTC Segment', 'All'],
    ['Meta Overall',     'DTC Segment', 'All'],
    ['Google Overall',   'DTC Segment', 'All']
  ]},
  'Sephora Traffic WoW': { shape: 'sephoraTraffic', grain: 'week', slides: [
    ['Sephora US Traffic', 'Sephora Segment', 'All'],
    ['Sephora CA Traffic', 'Sephora Segment', 'All'],
    ['Sephora @ Kohls',    'Sephora Segment', 'All']
  ]},
  'Sephora Collab WoW': { shape: 'sephoraCollab', grain: 'week', slides: [
    ['Sephora US Collab', 'Sephora Segment', 'All'],
    ['Sephora CA Collab', 'Sephora Segment', 'All'],
    ['Sephora – Total',   'Sephora Segment', 'All']
  ]},
  'Site': { shape: 'site', grain: 'week', slides: [
    ['All',          'Site', 'All'],
    ['Web',          'Site', 'All'],
    ['Subscription', 'Site', 'All']
  ]},
  'GA4 Channels': { shape: 'ga4', grain: 'week', slides: [
    ['Other',             'GA4 Channel', 'All'],
    ['Unattributed Paid', 'GA4 Channel', 'All']
  ]},
  // KPI table = MTD vs the same days of last month. Chart = the last 4 COMPLETE
  // months, because an mtd grain only ever holds two points.
  'MTD': { shape: 'dtc', grain: 'mtd', chartGrain: 'month', slides: [
    ['Paid DTC Overall', 'DTC Segment', 'All'],
    ['Meta Overall',     'DTC Segment', 'All'],
    ['Google Overall',   'DTC Segment', 'All']
  ]},
  'MTD Sephora': { shape: 'sephoraCollab', grain: 'mtd', chartGrain: 'month', slides: [
    ['Sephora – Total',   'Sephora Segment', 'All'],
    ['Sephora US Collab', 'Sephora Segment', 'All'],
    ['Sephora CA Collab', 'Sephora Segment', 'All']
  ]}
};

var C = { header:'#14201e', headerT:'#f6f5f0', block:'#f8f6f2', rule:'#e2ded4',
          amber:'#f4e9cf', amberT:'#8a6412', grey:'#eeeeee', greyT:'#999999',
          note:'#66756f', bar:'#14201e', line:'#c0703a' };

function buildReport() {
  var ss = SpreadsheetApp.getActive();
  ensureFeedTab_(ss);
  writeReadme_(ss);
  Object.keys(TABS).forEach(function (n) { buildTab_(ss, n, TABS[n]); });
  buildCampaigns_(ss);
  buildHealth_(ss);
  orderTabs_(ss);
  ss.toast('Rebuilt. Feed tab expected: "' + FEED + '"', 'Done', 8);
}

function sheet_(ss, name, wipe) {
  var sh = ss.getSheetByName(name);
  if (!sh) sh = ss.insertSheet(name);
  else if (wipe) {
    sh.clear();
    sh.clearConditionalFormatRules();
    // clear() leaves embedded charts behind, so a rebuild would stack a fresh
    // set on top of the old ones.
    sh.getCharts().forEach(function (ch) { sh.removeChart(ch); });
  }
  return sh;
}

function ensureFeedTab_(ss) {
  if (ss.getSheetByName(FEED)) return;
  var stale = ss.getSheetByName('feed');
  var sh = ss.insertSheet(FEED);
  sh.getRange('A1').setValue(
    'Connect the Metabase question "JM – Reporting Feed" (57484) here. Header row in ' +
    'row 1, 48 columns A:AV. Do not edit by hand.' +
    (stale ? '  NOTE: a tab named "feed" also exists — the extension names it ' +
             '"feed @ 57484", so the old one is stale and can be deleted.' : ''))
    .setFontColor(C.note).setFontStyle('italic').setWrap(true);
}

/**
 * period_start, counted back from the newest the feed holds. offset 0 = newest.
 * Reads column F (a date), NOT column E (display text) — see the header note.
 */
function periodAt_(level, grain, offsetFromNewest) {
  return '=IFERROR(INDEX(SORT(UNIQUE(FILTER(' + FEED_REF + '!' + PSTART + ',' +
         ' ' + FEED_REF + '!$A:$A="' + level + '", ' + FEED_REF + '!$D:$D="' + grain + '",' +
         ' ' + FEED_REF + '!' + PSTART + '<>"")),1,FALSE), ' + (offsetFromNewest + 1) + '), "")';
}

/**
 * The lookup key, exactly as the card builds it:
 *   report_level | row_label | market | grain | period
 * The period half comes off a date cell, rendered in the shape the card emits.
 */
function key_(level, row, market, grain, cellRef) {
  return '"' + level + '|' + row + '|' + market + '|' + grain + '|"&' +
         'TEXT(' + cellRef + ',"' + GRAIN[grain].key + '")';
}

/** One metric for one row/period. Row by lookup_key, metric BY HEADER NAME. */
function cell_(level, row, market, cellRef, grain, metric) {
  return '=IFERROR(INDEX(' + FEED_REF + '!' + COLS + ',' +
         ' MATCH(' + key_(level, row, market, grain, cellRef) + ',' +
         ' ' + FEED_REF + '!' + KEY + ', 0),' +
         ' MATCH("' + metric + '", ' + FEED_REF + '!$1:$1, 0)), "")';
}

function buildTab_(ss, name, cfg) {
  var shape = SHAPES[cfg.shape];
  var g     = GRAIN[cfg.grain];
  var cg    = cfg.chartGrain || cfg.grain;   // MTD tables chart complete months
  var gc    = GRAIN[cg];
  var sh    = sheet_(ss, name, true);

  sh.getRange(1, 1).setValue(name).setFontSize(14).setFontWeight('bold').setFontColor(C.headerT);
  sh.getRange(1, 1, 1, 5).setBackground(C.header);
  sh.getRange('A2').setValue('Data through:');
  sh.getRange('B2').setFormula('=IFERROR(TEXT(MAX(FILTER(' + FEED_REF + '!' + PSTART + ', ' +
    FEED_REF + '!$A:$A="' + cfg.slides[0][1] + '", ' + FEED_REF + '!$D:$D="' + cfg.grain +
    '")),"yyyy-mm-dd"),"— connect feed —")');
  if (cfg.grain === 'mtd') {
    // The header cells must hold dates (the lookup key is rebuilt from them),
    // so they can only render 'Sep 2026' — which hides that the window is 7
    // days, not a month. period_label carries the real span; nothing matches on
    // it, so it is safe to display verbatim.
    sh.getRange('D2').setFormula(
      '=IFERROR("Comparing "&TEXTJOIN(" vs ", TRUE, SORT(UNIQUE(FILTER(' +
      FEED_REF + '!$E:$E, ' + FEED_REF + '!$A:$A="' + cfg.slides[0][1] + '", ' +
      FEED_REF + '!$D:$D="mtd", ' + FEED_REF + '!$E:$E<>"")), 1, FALSE))&' +
      '" — equal-length windows, through the last complete day.", "")')
      .setFontColor(C.note).setFontStyle('italic');
  }
  sh.getRange('A3').setValue('Health:');
  sh.getRange('B3').setFormula('=COUNTIF(' + FEED_REF + '!$AU:$AU,"FAIL")&" checks failing"')
    .setFontColor(C.amberT);
  sh.getRange('A2:A3').setFontColor(C.note);

  var row = 5;
  cfg.slides.forEach(function (sl) {
    var label = sl[0], level = sl[1], market = sl[2];
    var blockTop = row;

    // ── slide title ────────────────────────────────────────────────────────
    sh.getRange(row, 1, 1, 2 + KPI_PERIODS).setBackground(C.block);
    sh.getRange(row, 1).setValue(label).setFontWeight('bold');
    row++;

    // ── KPI table: metrics as rows, oldest→newest, then % change ───────────
    var hdr = row;
    sh.getRange(row, 1).setValue(cfg.grain === 'mtd' ? 'Month to date' : 'Date')
      .setFontWeight('bold');
    for (var k = KPI_PERIODS - 1; k >= 0; k--) {
      sh.getRange(row, 1 + (KPI_PERIODS - k))
        .setFormula(periodAt_(level, cfg.grain, k))
        .setNumberFormat(g.fmt);
    }
    sh.getRange(row, 2 + KPI_PERIODS).setValue('% change').setFontWeight('bold');
    sh.getRange(row, 1, 1, 2 + KPI_PERIODS)
      .setFontWeight('bold').setBackground(C.block)
      .setBorder(null, null, true, null, null, null, C.rule, SpreadsheetApp.BorderStyle.SOLID);
    row++;

    var first = row;
    shape.metrics.forEach(function (m) {
      sh.getRange(row, 1).setValue(m[0]);
      for (var k = KPI_PERIODS - 1; k >= 0; k--) {
        var col = 1 + (KPI_PERIODS - k);
        sh.getRange(row, col).setFormula(
          cell_(level, label, market, colLetter_(col) + '$' + hdr, cfg.grain, m[1]))
          .setNumberFormat(m[2]);
      }
      var older = colLetter_(2), newer = colLetter_(1 + KPI_PERIODS);
      sh.getRange(row, 2 + KPI_PERIODS)
        .setFormula('=IFERROR(IF(' + older + row + '=0,"",' + newer + row + '/' + older + row + '-1),"")')
        .setNumberFormat('+0.0%;-0.0%;0.0%');
      row++;
    });
    // Conditional formats cannot reference another sheet, so the flag has to be
    // pulled onto this one first. One hidden row per block, one cell per period.
    if (shape.flag) {
      var flagRow = row;
      sh.getRange(flagRow, 1).setValue('flag (hidden)');
      for (var k = KPI_PERIODS - 1; k >= 0; k--) {
        var fc = 1 + (KPI_PERIODS - k);
        sh.getRange(flagRow, fc).setFormula(
          '=IFERROR(INDEX(' + FEED_REF + '!' + shape.flag + ',' +
          ' MATCH(' + key_(level, label, market, cfg.grain,
                           colLetter_(fc) + '$' + hdr) + ', ' +
          FEED_REF + '!' + KEY + ', 0)), TRUE)');
      }
      sh.hideRows(flagRow);
      addFlagRule_(sh, shape, first, shape.metrics.length, flagRow);
      row++;
    }
    row++;

    // ── chart data + the chart itself ──────────────────────────────────────
    sh.getRange(row, 1).setValue('Chart data  ·  last ' + CHART_PERIODS + ' complete ' + gc.noun)
      .setFontSize(9).setFontColor(C.note);
    row++;
    var chdr = row;
    sh.getRange(row, 1).setValue(gc.col).setFontWeight('bold');
    shape.chart.forEach(function (m, i) { sh.getRange(row, 2 + i).setValue(m[0]).setFontWeight('bold'); });
    row++;
    for (var k = CHART_PERIODS - 1; k >= 0; k--) {
      sh.getRange(row, 1).setFormula(periodAt_(level, cg, k)).setNumberFormat(gc.fmt);
      shape.chart.forEach(function (m, i) {
        sh.getRange(row, 2 + i)
          .setFormula(cell_(level, label, market, '$A' + row, cg, m[1]))
          .setNumberFormat(m[2]);
      });
      row++;
    }
    sh.getRange(chdr, 1, 1 + CHART_PERIODS, 1 + shape.chart.length)
      .setBorder(true, true, true, true, true, true, C.rule, SpreadsheetApp.BorderStyle.SOLID);
    addChart_(sh, shape, label, gc, chdr, blockTop);
    row += 2;
  });

  sh.getRange(row, 1).setValue(
    shape.flagStyle === 'amber'
      ? 'Amber = real Sephora spend with conversions unreported (no catalog-segment feedback). Act on it; do not fill it in.'
      : 'Grey = the underlying data does not exist for that period. Ignore; do not backfill.')
    .setFontColor(C.note).setFontSize(9);

  sh.setColumnWidth(1, 150);
  for (var c = 2; c <= 2 + KPI_PERIODS; c++) sh.setColumnWidth(c, 105);
  sh.setFrozenColumns(1);
  sh.setHiddenGridlines(true);
}

/**
 * The deck's "Spend vs ROAS" chart, for real: first chart metric as columns on
 * the left axis, second as a line on the right. Two axes because spend is in
 * thousands and ROAS is around 1 — on one axis the line would sit flat on zero.
 *
 * Anchored beside its own block (column F) so each chart travels with the table
 * it belongs to. Charts are removed and rebuilt on every run.
 */
function addChart_(sh, shape, label, g, chdr, anchorRow) {
  var bar = shape.chart[0], line = shape.chart[1];
  var chart = sh.newChart().asComboChart()
    .addRange(sh.getRange(chdr, 1, 1 + CHART_PERIODS, 1 + shape.chart.length))
    .setOption('title', label + ' — ' + bar[0] + ' vs ' + line[0])
    .setOption('titleTextStyle', { color: C.header, fontSize: 12, bold: true })
    .setOption('seriesType', 'bars')
    .setOption('series', {
      0: { type: 'bars', targetAxisIndex: 0, color: C.bar },
      1: { type: 'line', targetAxisIndex: 1, color: C.line, lineWidth: 3, pointSize: 6 }
    })
    .setOption('vAxes', {
      0: { title: bar[0],  format: bar[2].indexOf('$') === 0 ? 'currency' : 'short' },
      1: { title: line[0], format: line[2].indexOf('$') === 0 ? 'currency' : 'short',
           gridlines: { count: 0 } }
    })
    .setOption('hAxis', { title: g.col, format: g.hfmt, slantedText: false })
    .setOption('legend', { position: 'bottom' })
    .setOption('backgroundColor', '#ffffff')
    .setOption('chartArea', { left: 60, right: 60, top: 40, width: '76%', height: '62%' })
    .setOption('width', 460)
    .setOption('height', 260)
    .setPosition(anchorRow, 6, 0, 0)
    .build();
  sh.insertChart(chart);
}

/**
 * Google Sheets rejects a conditional-format formula that references another
 * sheet — "Conditional format rule cannot reference a different sheet." So the
 * rule points at a hidden row on THIS sheet, which does the cross-sheet lookup.
 *
 * The formula is anchored at the range's top-left, so B$<flagRow> keeps the row
 * pinned while the column walks across with the period columns. One rule covers
 * the whole block.
 */
function addFlagRule_(sh, shape, first, nRows, flagRow) {
  var rng = sh.getRange(first, 2, nRows, KPI_PERIODS);
  var rule = SpreadsheetApp.newConditionalFormatRule()
    .whenFormulaSatisfied('=' + colLetter_(2) + '$' + flagRow + '=FALSE')
    .setBackground(shape.flagStyle === 'amber' ? C.amber : C.grey)
    .setFontColor(shape.flagStyle === 'amber' ? C.amberT : C.greyT)
    .setRanges([rng]).build();
  var rules = sh.getConditionalFormatRules(); rules.push(rule);
  sh.setConditionalFormatRules(rules);
}

function buildCampaigns_(ss) {
  var sh = sheet_(ss, 'Campaigns', true);
  sh.getRange('A1').setValue('Campaigns').setFontSize(14).setFontWeight('bold').setFontColor(C.headerT);
  sh.getRange('A1:I1').setBackground(C.header);
  sh.getRange('A2').setValue('Week:');
  sh.getRange('B2').setFormula(periodAt_('Campaign', 'week', 0)).setNumberFormat(GRAIN.week.fmt);
  sh.getRange('A3').setValue('read_metrics says which family applies: Sephora rows use cs_*, DTC rows use paid_*.')
    .setFontColor(C.note).setFontSize(9);
  // Filters on F (the date) rather than E (display text) — QUERY needs a real
  // date literal, and B2 is a date, so TEXT() puts it in the shape QUERY wants.
  sh.getRange('A5').setFormula(
    '=IFERROR(QUERY(' + FEED_REF + '!' + COLS + ',' +
    ' "select B, C, G, I, O, Q, X, AB, AD' +
    '   where A = \'Campaign\' and D = \'week\' and F = date \'"&TEXT($B$2,"yyyy-mm-dd")&"\'' +
    '   order by I desc' +
    '   label B \'Campaign\', C \'Market\', G \'Read\', I \'Spend\', O \'Paid purch\',' +
    ' Q \'Paid ROAS\', X \'GA4 ROAS\', AB \'cs purch\', AD \'cs ROAS\'", 1),' +
    ' "No rows — check the feed tab name is exactly: ' + FEED + '")');
  sh.setColumnWidth(1, 460); sh.setFrozenRows(5);
}

function buildHealth_(ss) {
  var sh = sheet_(ss, 'Health', true);
  sh.getRange('A1').setValue('Data Health').setFontSize(14).setFontWeight('bold').setFontColor(C.headerT);
  sh.getRange('A1:C1').setBackground(C.header);
  sh.getRange('A2').setValue('Any FAIL invalidates the numbers above it. Check before sending a report.')
    .setFontColor(C.note).setFontSize(9);
  sh.getRange('A4').setFormula(
    '=IFERROR(QUERY(' + FEED_REF + '!' + COLS + ',' +
    ' "select B, AU, AV where A = \'Health\' order by AU desc, B' +
    '   label B \'Check\', AU \'Status\', AV \'Detail\'", 1),' +
    ' "No rows — check the feed tab name is exactly: ' + FEED + '")');
  sh.setConditionalFormatRules([
    SpreadsheetApp.newConditionalFormatRule().whenTextEqualTo('FAIL')
      .setBackground('#f5e2dc').setFontColor('#96331f').setBold(true)
      .setRanges([sh.getRange('A4:C200')]).build(),
    SpreadsheetApp.newConditionalFormatRule().whenTextEqualTo('OK')
      .setFontColor('#33604a').setRanges([sh.getRange('A4:C200')]).build()
  ]);
  sh.setColumnWidth(1, 300); sh.setColumnWidth(2, 80); sh.setColumnWidth(3, 400);
  sh.setFrozenRows(4);
}

function writeReadme_(ss) {
  var sh = sheet_(ss, 'README', true);
  var L = [
    ['Josie Maran — Automated Reporting'],
    [''],
    ['FEED TAB: "' + FEED + '"  — the extension appends the question id (57484).'],
    ['48 columns A:AV. Never edit, sort or format that tab.'],
    [''],
    ['LAYOUT MATCHES THE DECK. Each block is one slide: metrics down the rows,'],
    ['two date columns plus % change, and a ' + CHART_PERIODS + '-period combo chart beside it'],
    ['(columns = spend, line = ROAS on its own axis). The feed carries 7 weeks and'],
    ['3 months; the window is applied in the script, so changing it never means'],
    ['editing SQL — see KPI_PERIODS / CHART_PERIODS.'],
    [''],
    ['PERIODS ARE MATCHED AS DATES, NOT AS LABELS. Sheets auto-parses anything'],
    ['date-shaped, so the label "2026-08" silently became the serial 46235 and'],
    ['every lookup built from it missed. Header cells now read period_start'],
    ['(column F, a real date) and rebuild the key with TEXT(); the display format'],
    ['is cosmetic. Never point a lookup at column E — it is display text only.'],
    [''],
    ['FOUR CONVERSION SOURCES. CHECK COLUMN G (read_metrics) FIRST.'],
    ['  paid_*  Meta/Google own pixel, with a view-through window'],
    ['  ga4_*   GA4 last-non-direct session attribution'],
    ['  cs_*    Sephora, via catalog segment actions — the ONLY place it converts'],
    ['  site_*  what Shopify actually booked'],
    ['paid_roas and ga4_roas will disagree. The DTC slides show both. Never add them.'],
    [''],
    ['NO TARGET ROAS ANYWHERE IN THIS BOOK. The deck does not carry targets, so'],
    ['nothing here invents one. If the client sets them, add a column to the'],
    ['campaign_segments seed rather than hardcoding numbers in the script.'],
    [''],
    ['MTD COMPARES EQUAL WINDOWS, NOT A PART-MONTH AGAINST A WHOLE ONE. The month'],
    ['grain excludes the month in progress, so an MTD tab built on it showed the'],
    ['last two COMPLETE months. The card now emits a third grain, mtd: this month'],
    ['through the last complete day, and the SAME number of days of last month —'],
    ['Sep 1-7 vs Aug 1-7. The KPI table reads mtd; the chart still reads the last 4'],
    ['complete months, because mtd only ever holds two points.'],
    ['Today is excluded from every window: it is still filling.'],
    [''],
    ['WEEKS START ON SUNDAY, because the client asked for it. dbt_project.yml sets'],
    ['week_start: Sunday and the packages honour it, so every weekly row is anchored'],
    ['on a Sunday (2026-08-16 / 08-23 / 08-30 / 09-06).'],
    [''],
    ['GA4 CHANNEL MAPPING'],
    ['  metaads / paidsocial -> Meta     google / cpc -> Google     else -> Other'],
    ['TikTok has no mapping — no DTC TikTok campaigns exist. Google\'s'],
    ['session_campaign_id is the campaign id; Meta\'s is <adset_id>_v2_sNN, so it'],
    ['needs an adset->campaign lookup (99.2% resolves). GA4 that attaches to no'],
    ['campaign appears on GA4 Channels as "Other" or "Unattributed Paid", so total'],
    ['GA4 revenue reconciles instead of disappearing.'],
    [''],
    ['SEPHORA TRAFFIC HAS NO CONVERSION ROWS, AND THAT IS NOT AN OMISSION.'],
    ['US/CA Traffic and @ Kohls emit no catalog-segment rows, so there is no honest'],
    ['Sephora purchase figure. Those slides show delivery only. Amber = real spend,'],
    ['conversions unreported. Collab does report: US 4.82 ROAS, CA 4.64 in the week'],
    ['of 8/31, on 5% of Sephora spend and all 145 measured purchases.'],
    [''],
    ['SEGMENTS COME FROM CAMPAIGN IDS, NOT NAMES — seeds/campaign_segments.csv in'],
    ['bolt-josiemaran, from the reporting deck. An unmapped id gets segment'],
    ['"Unmapped", appears on NO segment row, and is reported on the Health tab.'],
    [''],
    ['GREY = DTC BLENDED METRICS START THE WEEK OF 2026-07-27. Shopify order history'],
    ['begins there. August 2026 is the only complete month, so no blended MoM until'],
    ['October. Sephora has catalog-segment history from 2025-03; GA4 from 2024-08.'],
    [''],
    ['READ FRESHNESS OFF THE HEALTH TAB; DO NOT ASSUME IT. Google Ads was 8 days'],
    ['behind when this was built and is level with Meta and Shopify as of'],
    ['2026-09-08 — a sync condition, not a standing property. The freshness check'],
    ['reports it live per channel.'],
    ['Google\'s ~1,100% ROAS is correct — branded search is run to a deliberate'],
    ['1,000% tROAS.'],
    [''],
    ['TO REBUILD: Extensions -> Apps Script -> Save -> Run buildReport. Metric sets'],
    ['live in SHAPES, slides in TABS, colours in C.']
  ];
  sh.getRange(1, 1, L.length, 1).setValues(L);
  sh.getRange(1, 1).setFontSize(14).setFontWeight('bold');
  // Bold every ALL-CAPS section opener, rather than a hand-kept row list that
  // silently drifts one line at a time as this text is edited.
  for (var i = 0; i < L.length; i++) {
    var t = L[i][0];
    if (t && t === t.toUpperCase() && /[A-Z]{4}/.test(t)) sh.getRange(i + 1, 1).setFontWeight('bold');
  }
  sh.setColumnWidth(1, 800);
  sh.getRange(1, 1, L.length, 1).setVerticalAlignment('top');
  sh.setHiddenGridlines(true);
}

function orderTabs_(ss) {
  ['README','Health','DTC WoW','MTD','Sephora Traffic WoW','Sephora Collab WoW',
   'MTD Sephora','GA4 Channels','Site','Campaigns', FEED].forEach(function (n, i) {
    var sh = ss.getSheetByName(n);
    if (sh) { ss.setActiveSheet(sh); ss.moveActiveSheet(i + 1); }
  });
  var r = ss.getSheetByName('README'); if (r) ss.setActiveSheet(r);
}

function colLetter_(n) {
  var s = '';
  while (n > 0) { var m = (n - 1) % 26; s = String.fromCharCode(65 + m) + s; n = (n - m - 1) / 26; }
  return s;
}
