/**
 * Josie Maran — Automated Reporting
 * RUN: Extensions → Apps Script → paste → Save → Run ▸ buildReport
 * Idempotent. Never touches the feed tab, which the Metabase extension owns.
 *
 * ── LAYOUT MIRRORS THE DECK, NOT A GENERIC GRID ─────────────────────────────
 * Two block shapes, matching the two slide types in the deck:
 *   comparison  WoW/MoM tabs. Metrics as rows, 2 periods + % change, plus a
 *               combo chart over the last 4 periods. buildComparisonBlock_.
 *   summary     MTD tabs. ONE row — Spend, CTR, CVR, Revenue, ROAS, AOV — plus
 *               the same 4-week trend chart every other tab draws (an mtd
 *               grain only ever holds one useful point, so there is no
 *               monthly trend to draw). buildMtdSummaryBlock_.
 *
 * The feed supplies 7 weeks, 3 months and 2 mtd rows. The window is applied
 * here, not in the card, so changing it never means editing SQL.
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
var COLS     = '$A:$AX';        // 50 columns (48 metrics/flags + 2 slide-config columns)
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
    // The MTD tab's flat summary row, per slide 3: Spend, CTR, CVR, Revenue,
    // ROAS, AOV.
    summary: [
      ['Spend',   'spend',        '$#,##0'],
      ['CTR',     'ctr',          '0.00%'],
      ['CVR',     'paid_cvr',     '0.00%'],
      ['Revenue', 'paid_revenue', '$#,##0'],
      ['ROAS',    'paid_roas',    '0.00'],
      ['AOV',     'paid_aov',     '$#,##0.00']
    ],
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
    // MTD summary is identical to the WoW detail table here — this shape only
    // ever had 5 metrics.
    summary: [
      ['Spend',  'spend',  '$#,##0'],
      ['CPM',    'cpm',    '$0.00'],
      ['CTR',    'ctr',    '0.00%'],
      ['Clicks', 'clicks', '#,##0'],
      ['CPC',    'cpc',    '$0.00']
    ]
    // No flag. has_catalog_feedback is FALSE for every Traffic row, always —
    // these campaigns structurally never carry catalog-segment tracking, so
    // that isn't an anomaly to act on, it's the permanent baseline. Flagging
    // it painted the whole table amber forever, which said nothing. Collab
    // keeps the flag: it DOES normally get feedback, so its absence there is
    // a real signal.
  },
  sephoraCollab: {
    // WoW detail table, matching slides 10/12 exactly — Clicks, Purchases,
    // Revenue and % in store are in the card but not shown on this table.
    metrics: [
      ['Spend', 'spend',   '$#,##0'],
      ['CPM',   'cpm',     '$0.00'],
      ['CTR',   'ctr',     '0.00%'],
      ['CPC',   'cpc',     '$0.00'],
      ['CVR',   'cs_cvr',  '0.00%'],
      ['CPA',   'cs_cpa',  '$#,##0.00'],
      ['ROAS',  'cs_roas', '0.00'],
      ['AOV',   'cs_aov',  '$#,##0.00']
    ],
    chart: [['Spend', 'spend', '$#,##0'], ['ROAS', 'cs_roas', '0.00']],
    // MTD summary row for Collab is DELIVERY ONLY, same 5 metrics as Traffic
    // (slides 10/12), not the conversion metrics above — catalog-segment
    // feedback lags, so the most recent days rarely have it in yet. Triples,
    // not keys: 'clicks' isn't in this shape's own `metrics` above, since the
    // WoW table doesn't show it.
    summary: [
      ['Spend',  'spend',  '$#,##0'],
      ['CPM',    'cpm',    '$0.00'],
      ['CTR',    'ctr',    '0.00%'],
      ['Clicks', 'clicks', '#,##0'],
      ['CPC',    'cpc',    '$0.00']
    ],
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

// Two kinds of tab now. Most name `shapes` — the slide LIST is read off the
// feed at runtime (loadSlideConfig_), driven by seeds/segment_report_config.csv
// in the repo. Adding a segment there (+ a matching campaign_segments.csv
// entry, + dbt run, + re-pasting the card) makes it appear here with NO
// script edit. A few tabs (Site, GA4 Channels) aren't segment-driven — their
// rows come from order_type / a fixed GA4 residual split, not a seed — so
// they keep an explicit `slides` array, same as before this existed.
var TABS = {
  'DTC WoW': { shape: 'dtc', grain: 'week', shapes: ['dtc'] },
  'Sephora Traffic WoW': { shape: 'sephoraTraffic', grain: 'week', shapes: ['sephoraTraffic'] },
  'Sephora Collab WoW': { shape: 'sephoraCollab', grain: 'week', shapes: ['sephoraCollab'] },
  'Site': { shape: 'site', grain: 'week', slides: [
    ['All',          'Site', 'All'],
    ['Web',          'Site', 'All'],
    ['Subscription', 'Site', 'All']
  ]},
  'GA4 Channels': { shape: 'ga4', grain: 'week', slides: [
    ['Other',             'GA4 Channel', 'All'],
    ['Unattributed Paid', 'GA4 Channel', 'All']
  ]},
  // KPI = one row, current MTD only (Spend/CTR/CVR/Revenue/ROAS/AOV — the deck's
  // "Full Funnel KPIs" slide). Chart = the same 4-week trend as every WoW tab:
  // mtd only ever holds one useful point, so there is no monthly trend to draw.
  'MTD': { shape: 'dtc', grain: 'mtd', chartGrain: 'week', shapes: ['dtc'] },
  // Two shapes mixed in one tab (Traffic charts Spend/CPC, Collab charts
  // Spend/ROAS) — shapes is an ARRAY here, and loadSlideConfig_ groups by
  // shape-in-array-order first, sort_order within each shape second, which is
  // what keeps Traffic's 3 slides ahead of Collab's 2 without needing a
  // single shared sort key across both shapes in the seed.
  'MTD Sephora': { grain: 'mtd', chartGrain: 'week', shapes: ['sephoraTraffic', 'sephoraCollab'] }
};

var C = { header:'#14201e', headerT:'#f6f5f0', block:'#f8f6f2', rule:'#e2ded4',
          amber:'#f4e9cf', amberT:'#8a6412', grey:'#eeeeee', greyT:'#999999',
          note:'#66756f', bar:'#4285f4', line:'#8e7cc3' };

function buildReport() {
  var ss = SpreadsheetApp.getActive();
  ensureFeedTab_(ss);
  writeReadme_(ss);
  var slideConfig = loadSlideConfig_(ss);
  Object.keys(TABS).forEach(function (n) { buildTab_(ss, n, TABS[n], slideConfig); });
  buildCampaigns_(ss);
  buildHealth_(ss);
  upsertPendingCharts_();
  orderTabs_(ss);
  ss.toast('Rebuilt. Feed tab expected: "' + FEED + '"', 'Done', 8);
}

/**
 * Read the feed ONCE and return every (report_level, row_label, market) that
 * carries a non-blank slide_shape — the two trailing columns
 * gen_reporting_feed.py joins in from seeds/segment_report_config.csv. This
 * is what a `shapes:`-based TABS entry draws its slide list from, instead of
 * a hardcoded array: a segment shows up here the moment it exists in the
 * feed with a shape assigned, no script edit needed.
 *
 * Reads header names, not fixed letters — this one function is the exception
 * to "never trust column position" elsewhere in this file, specifically so
 * it keeps working if more columns are ever appended after slide_sort.
 */
function loadSlideConfig_(ss) {
  var sh = ss.getSheetByName(FEED);
  if (!sh || sh.getLastRow() < 2) return [];
  var values = sh.getDataRange().getValues();
  var header = values[0];
  var idx = {};
  ['report_level', 'row_label', 'market', 'slide_shape', 'slide_sort'].forEach(function (name) {
    idx[name] = header.indexOf(name);
  });
  if (idx.slide_shape < 0 || idx.slide_sort < 0) {
    throw new Error('Feed tab has no slide_shape/slide_sort columns — re-paste ' +
                    'the card from metabase/01_reporting_feed.sql (needs the ' +
                    'slide_config join) and refresh.');
  }

  var seen = {}, out = [];
  for (var r = 1; r < values.length; r++) {
    var row = values[r];
    var shape = row[idx.slide_shape];
    if (!shape) continue;
    var level = row[idx.report_level], label = row[idx.row_label], market = row[idx.market];
    var key = level + '|' + label + '|' + market;
    if (seen[key]) continue;
    seen[key] = true;
    out.push({ level: level, label: label, market: market,
               shape: shape, sort: Number(row[idx.slide_sort]) || 0 });
  }
  return out;
}

/**
 * cfg.slides if the tab still declares one literally (Site, GA4 Channels —
 * not segment-driven). Otherwise built from slideConfig: group by shape IN
 * THE ORDER cfg.shapes lists them, sort_order within each shape — this is
 * what keeps e.g. MTD Sephora's 3 Traffic slides ahead of its 2 Collab
 * slides without the seed needing a single sort key shared across shapes.
 */
function resolveSlides_(cfg, slideConfig) {
  if (cfg.slides) return cfg.slides;
  var out = [];
  cfg.shapes.forEach(function (shapeName) {
    slideConfig
      .filter(function (e) { return e.shape === shapeName; })
      .sort(function (a, b) { return a.sort - b.sort; })
      .forEach(function (e) { out.push([e.label, e.level, e.market, shapeName]); });
  });
  return out;
}

function sheet_(ss, name, wipe) {
  var sh = ss.getSheetByName(name);
  if (!sh) sh = ss.insertSheet(name);
  else if (wipe) {
    sh.clear();
    sh.clearConditionalFormatRules();
    // Charts are deliberately NOT removed here. clear() doesn't touch them,
    // and destroying them would be the one thing that makes linking this
    // book into Google Slides impossible: a Slides-linked chart references
    // the embedded chart's object ID, so remove-then-reinsert hands it a new
    // ID every run and orphans the slide. upsertPendingCharts_() edits the
    // existing chart in place instead, preserving identity, and prunes only
    // the charts this run no longer produces.
  }
  return sh;
}

function ensureFeedTab_(ss) {
  if (ss.getSheetByName(FEED)) return;
  var stale = ss.getSheetByName('feed');
  var sh = ss.insertSheet(FEED);
  sh.getRange('A1').setValue(
    'Connect the Metabase question "JM – Reporting Feed" (57484) here. Header row in ' +
    'row 1, 50 columns A:AX. Do not edit by hand.' +
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

/**
 * The MTD block: one row, current month-to-date only — matching the deck's
 * "Full Funnel KPIs" slide, which shows MTD as a single flat row of numbers,
 * not a period-over-period comparison. Returns the next free row.
 */
function buildMtdSummaryBlock_(sh, shape, level, label, market, row) {
  var g = GRAIN.mtd;
  var cols = shape.summary;

  var hdr = row;
  sh.getRange(row, 1).setFormula('=TEXT(TODAY(),"mmm")&" MTD"').setFontWeight('bold');
  cols.forEach(function (m, i) { sh.getRange(row, 2 + i).setValue(m[0]).setFontWeight('bold'); });
  sh.getRange(row, 1, 1, 1 + cols.length)
    .setFontWeight('bold').setBackground(C.block)
    .setBorder(null, null, true, null, null, null, C.rule, SpreadsheetApp.BorderStyle.SOLID);
  row++;

  var valRow = row;
  sh.getRange(row, 1).setFormula(periodAt_(level, 'mtd', 0)).setNumberFormat(g.fmt);
  cols.forEach(function (m, i) {
    sh.getRange(row, 2 + i)
      .setFormula(cell_(level, label, market, '$A' + valRow, 'mtd', m[1]))
      .setNumberFormat(m[2]);
  });
  row++;

  // Same hidden-row trick as the comparison block: conditional formats can't
  // reference another sheet, so the flag is pulled onto this one first.
  if (shape.flag) {
    var flagRow = row;
    sh.getRange(flagRow, 1).setValue('flag (hidden)');
    sh.getRange(flagRow, 2).setFormula(
      '=IFERROR(INDEX(' + FEED_REF + '!' + shape.flag + ',' +
      ' MATCH(' + key_(level, label, market, 'mtd', '$A$' + valRow) + ', ' +
      FEED_REF + '!' + KEY + ', 0)), TRUE)');
    sh.hideRows(flagRow);
    var rng = sh.getRange(valRow, 2, 1, cols.length);
    var rule = SpreadsheetApp.newConditionalFormatRule()
      .whenFormulaSatisfied('=$B$' + flagRow + '=FALSE')
      .setBackground(shape.flagStyle === 'amber' ? C.amber : C.grey)
      .setFontColor(shape.flagStyle === 'amber' ? C.amberT : C.greyT)
      .setRanges([rng]).build();
    var rules = sh.getConditionalFormatRules(); rules.push(rule);
    sh.setConditionalFormatRules(rules);
    row++;
  }
  return row;
}

/**
 * The comparison block every WoW/MoM tab uses: metrics as rows, oldest →
 * newest, then % change. Returns the next free row.
 */
function buildComparisonBlock_(sh, shape, level, label, market, grain, g, row) {
  var hdr = row;
  sh.getRange(row, 1).setValue('Date').setFontWeight('bold');
  for (var k = KPI_PERIODS - 1; k >= 0; k--) {
    sh.getRange(row, 1 + (KPI_PERIODS - k))
      .setFormula(periodAt_(level, grain, k))
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
        cell_(level, label, market, colLetter_(col) + '$' + hdr, grain, m[1]))
        .setNumberFormat(m[2]);
    }
    var older = colLetter_(2), newer = colLetter_(1 + KPI_PERIODS);
    sh.getRange(row, 2 + KPI_PERIODS)
      .setFormula('=IFERROR(IF(' + older + row + '=0,"",' + newer + row + '/' + older + row + '-1),"")')
      .setNumberFormat('+0.0%;-0.0%;0.0%');
    row++;
  });
  if (shape.flag) {
    var flagRow = row;
    sh.getRange(flagRow, 1).setValue('flag (hidden)');
    for (var k = KPI_PERIODS - 1; k >= 0; k--) {
      var fc = 1 + (KPI_PERIODS - k);
      sh.getRange(flagRow, fc).setFormula(
        '=IFERROR(INDEX(' + FEED_REF + '!' + shape.flag + ',' +
        ' MATCH(' + key_(level, label, market, grain,
                         colLetter_(fc) + '$' + hdr) + ', ' +
        FEED_REF + '!' + KEY + ', 0)), TRUE)');
    }
    sh.hideRows(flagRow);
    addFlagRule_(sh, shape, first, shape.metrics.length, flagRow);
    row++;
  }
  return row;
}

function buildTab_(ss, name, cfg, slideConfig) {
  var slides = resolveSlides_(cfg, slideConfig);
  var g     = GRAIN[cfg.grain];
  var cg    = cfg.chartGrain || cfg.grain;
  var gc    = GRAIN[cg];
  var sh    = sheet_(ss, name, true);
  var isMtd = cfg.grain === 'mtd';

  sh.getRange(1, 1).setValue(name).setFontSize(14).setFontWeight('bold').setFontColor(C.headerT);
  sh.getRange(1, 1, 1, 5).setBackground(C.header);
  sh.getRange('A2').setValue('Data through:');
  if (isMtd) {
    // mtd rows are stamped with the month start (2026-09-01), not the last
    // day covered — the card guarantees "through yesterday" by construction
    // (see the md CTE in gen_reporting_feed.py), so state that directly
    // rather than reading a date that would just show the 1st every time.
    sh.getRange('B2').setFormula('=TEXT(TODAY()-1,"yyyy-mm-dd")');
  } else if (slides.length) {
    sh.getRange('B2').setFormula('=IFERROR(TEXT(MAX(FILTER(' + FEED_REF + '!' + PSTART + ', ' +
      FEED_REF + '!$A:$A="' + slides[0][1] + '", ' + FEED_REF + '!$D:$D="' + cfg.grain +
      '")),"yyyy-mm-dd"),"— connect feed —")');
  } else {
    sh.getRange('B2').setValue('— no segments configured for this tab —');
  }
  sh.getRange('A3').setValue('Health:');
  sh.getRange('B3').setFormula('=COUNTIF(' + FEED_REF + '!$AU:$AU,"FAIL")&" checks failing"')
    .setFontColor(C.amberT);
  sh.getRange('A2:A3').setFontColor(C.note);

  var row = 5, lastShape = null;
  slides.forEach(function (sl) {
    var label = sl[0], level = sl[1], market = sl[2];
    var shape = SHAPES[sl[3] || cfg.shape];
    lastShape = shape;
    var titleW = isMtd ? 1 + shape.summary.length : 2 + KPI_PERIODS;
    var blockTop = row;

    // ── slide title ────────────────────────────────────────────────────────
    sh.getRange(row, 1, 1, titleW).setBackground(C.block);
    sh.getRange(row, 1).setValue(label).setFontWeight('bold');
    row++;

    row = isMtd
      ? buildMtdSummaryBlock_(sh, shape, level, label, market, row)
      : buildComparisonBlock_(sh, shape, level, label, market, cfg.grain, g, row);
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
    // Charts are not built here. Apps Script builds an embedded chart from
    // the CURRENT values in its source range — building one mid-run, right
    // after writing its own data, risks racing the recalculation of every
    // other formula still pending across a big multi-tab workbook. Queue the
    // spec instead; upsertPendingCharts_() builds all of them in one pass
    // after the whole report is written and flushed.
    queueChart_(sh, shape, label, gc, chdr, blockTop);
    row += 2;
  });

  // Only caption a legend if the last slide's shape actually carries a flag —
  // sephoraTraffic has none, so a tab entirely made of Traffic slides (like
  // Sephora Traffic WoW) gets no caption rather than a stale amber/grey one.
  // lastShape can be null if a shapes-based tab resolved to zero slides.
  if (lastShape && lastShape.flag) {
    sh.getRange(row, 1).setValue(
      lastShape.flagStyle === 'amber'
        ? 'Amber = real Sephora spend with conversions unreported (no catalog-segment feedback). Act on it; do not fill it in.'
        : 'Grey = the underlying data does not exist for that period. Ignore; do not backfill.')
      .setFontColor(C.note).setFontSize(9);
  }

  sh.setColumnWidth(1, isMtd ? 130 : 150);
  for (var c = 2; c <= 9; c++) sh.setColumnWidth(c, isMtd ? 95 : 105);
  sh.setFrozenColumns(1);
  sh.setHiddenGridlines(true);
}

/**
 * Queue a chart spec instead of building it immediately — see the comment at
 * the call site in buildTab_. All charts are actually built by
 * upsertPendingCharts_(), once, at the very end of buildReport().
 */
var PENDING_CHARTS_ = [];

function queueChart_(sh, shape, label, g, chdr, anchorRow) {
  PENDING_CHARTS_.push({ sh: sh, shape: shape, label: label, g: g, chdr: chdr, anchorRow: anchorRow });
}

/**
 * The deck's "Spend vs ROAS" chart, for real: first chart metric as columns on
 * the left axis, second as a line on the right. Two axes because spend is in
 * thousands and ROAS is around 1 — on one axis the line would sit flat on zero.
 *
 * Anchored beside its own block (column F) so each chart travels with the block
 * it belongs to. Charts are removed at the top of each tab rebuild (sheet_)
 * and all rebuilt here, after every tab's data has been written and flushed —
 * a chart built mid-run, right after writing its own data, can snapshot
 * before Sheets finishes recalculating and render as an empty box.
 */
function upsertPendingCharts_() {
  SpreadsheetApp.flush();

  // Group this run's specs by sheet, so each sheet's surviving-title set can
  // be computed and stale charts pruned in one pass.
  var bySheet = {};
  PENDING_CHARTS_.forEach(function (spec) {
    var key = spec.sh.getSheetName();
    (bySheet[key] = bySheet[key] || { sh: spec.sh, specs: [] }).specs.push(spec);
  });

  Object.keys(bySheet).forEach(function (key) {
    var sh = bySheet[key].sh, specs = bySheet[key].specs;
    var existing = sh.getCharts();
    var wanted = {};

    specs.forEach(function (spec) {
      var shape = spec.shape, label = spec.label, g = spec.g;
      var bar = shape.chart[0], line = shape.chart[1];
      var title = label + ' — ' + bar[0] + ' vs ' + line[0];
      wanted[title] = true;

      // Match on title, not anchor row: titles are unique per tab and stable,
      // whereas row positions shift whenever a metric list changes length.
      var match = null;
      for (var i = 0; i < existing.length; i++) {
        if (chartTitle_(existing[i]) === title) { match = existing[i]; break; }
      }

      // modify() returns a builder bound to the EXISTING chart, so build()
      // + updateChart() edits it in place and the object ID survives — which
      // is what keeps a Slides link pointing at it alive across rebuilds.
      var b = match ? match.modify() : sh.newChart().asComboChart();
      if (match) b.clearRanges();
      b.addRange(sh.getRange(spec.chdr, 1, 1 + CHART_PERIODS, 1 + shape.chart.length))
        .setNumHeaders(1)
        .setOption('title', title)
        .setOption('series', {
          0: { type: 'bars', targetAxisIndex: 0, color: C.bar, dataLabel: 'value' },
          1: { type: 'line', targetAxisIndex: 1, color: C.line, lineWidth: 3, pointSize: 6, dataLabel: 'value' }
        })
        .setOption('vAxes', { 0: { title: bar[0] }, 1: { title: line[0] } })
        .setOption('hAxis', { title: g.col })
        .setOption('legend', { position: 'bottom' })
        .setOption('width', 460)
        .setOption('height', 260)
        .setPosition(spec.anchorRow, 6, 0, 0);

      if (match) sh.updateChart(b.build());
      else       sh.insertChart(b.build());
    });

    // Prune only what this run genuinely no longer produces — e.g. a chart
    // left behind after a metric list or slide list changed.
    existing.forEach(function (ch) {
      var t = chartTitle_(ch);
      if (t && !wanted[t]) sh.removeChart(ch);
    });
  });

  PENDING_CHARTS_ = [];
}

/** A chart's title option, or '' if it has none. Used as its stable identity. */
function chartTitle_(chart) {
  try { return chart.getOptions().get('title') || ''; } catch (e) { return ''; }
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
    ['50 columns A:AX. Never edit, sort or format that tab.'],
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
['MTD IS ONE ROW, CURRENT MONTH ONLY — NOT A COMPARISON. The month grain'],
    ['excludes the month in progress, so an MTD table built on it showed the last'],
    ['two COMPLETE months instead (Aug next to Jul). The card now emits a third'],
    ['grain, mtd: this month through the last complete day (today is excluded —'],
    ['it is still filling). The MTD tab shows that single row — Spend, CTR, CVR,'],
    ['Revenue, ROAS, AOV, matching the deck\'s "Full Funnel KPIs" slide — and the'],
    ['chart beneath it is the same 4-week trend every WoW tab draws, not a'],
    ['monthly one: mtd only ever holds one useful point, so there is no monthly'],
    ['trend to draw from it.'],
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
    ['WHICH SEGMENTS GET THEIR OWN SLIDE IS SEED-DRIVEN, NOT SCRIPT-HARDCODED.'],
    ['seeds/segment_report_config.csv (row_label, shape, sort_order) joins into'],
    ['the card as slide_shape/slide_sort (cols AW/AX). loadSlideConfig_ reads'],
    ['those off the feed at runtime for any TABS entry that declares `shapes`'],
    ['instead of a literal `slides` array. A new segment (new campaign_segments.csv'],
    ['row + a row here + dbt run + re-paste the card) appears on the next'],
    ['refreshAndRebuild() with no Apps Script edit. Site and GA4 Channels are'],
    ['not segment-driven and still use a literal `slides` array — that is fine,'],
    ['not a gap to close.'],
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
    ['CHARTS ARE UPDATED IN PLACE, NOT REBUILT — THIS IS LOAD-BEARING FOR SLIDES.'],
    ['A Slides-linked chart references the embedded chart OBJECT ID, so deleting'],
    ['and reinserting a chart orphans the slide silently. upsertPendingCharts_'],
    ['matches each chart by title, edits it via modify() + updateChart() so the'],
    ['ID survives, and prunes only charts a run no longer produces. Do not'],
    ['"simplify" that back to removeChart + insertChart.'],
    ['Linked RANGES (tables) survive a rebuild too, but they are addressed by'],
    ['A1 range — so changing a metric list shifts every block below it and the'],
    ['slide then points at the wrong rows. Re-link after any layout change.'],
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

/* ════════════════════════════════════════════════════════════════════════════
   SELF-REFRESH — pull the feed straight from Metabase, no extension needed
   ════════════════════════════════════════════════════════════════════════════

   PASTE YOUR CREDENTIALS HERE  ▼▼▼  (or better, use Script Properties — see below)

   Two ways to supply them, checked in this order:

   1. Script Properties (recommended — keeps secrets out of the source, so the
      key is not in version control or visible to anyone who opens the editor):
        Apps Script editor -> Project Settings (gear) -> Script Properties
        -> Add property:  METABASE_API_KEY  =  <your key>
        -> Add property:  METABASE_URL      =  https://<your-metabase-host>

   2. Or just fill the two constants below and leave Script Properties empty.

   Get an API key: Metabase -> Settings (gear) -> Admin settings -> Authentication
   -> API keys -> Create API key. Give it a group with read access to the
   Josie Maran database. It is shown once — copy it then.
   ════════════════════════════════════════════════════════════════════════════ */

// DO NOT PUT REAL VALUES HERE. This file is committed to a public-ish git
// history; anything typed on these two lines gets pushed in plaintext and
// stays recoverable from old commits even after being edited out later. A
// real key WAS committed here once already (rotated after discovery) —
// use Script Properties instead: Project Settings (gear) -> Script
// Properties -> METABASE_API_KEY / METABASE_URL. That storage is per-project,
// never touches source, and is what mbConfig_() below checks FIRST.
var METABASE_API_KEY = 'PASTE_METABASE_API_KEY_HERE';           // <<< PLACEHOLDER — leave as-is, use Script Properties
var METABASE_URL     = 'PASTE_METABASE_BASE_URL_HERE';          // <<< PLACEHOLDER — leave as-is, use Script Properties
                                                                 // e.g. https://metabase.superbolt.agency
var CARD_ID          = 57484;                                    // "JM – Reporting Feed"

/** Script Properties win over the inline constants above. */
function mbConfig_() {
  var props = PropertiesService.getScriptProperties();
  var key = props.getProperty('METABASE_API_KEY') || METABASE_API_KEY;
  var url = props.getProperty('METABASE_URL')     || METABASE_URL;
  if (!key || key.indexOf('PASTE_') === 0) {
    throw new Error('No Metabase API key. Set the METABASE_API_KEY script property, ' +
                    'or fill METABASE_API_KEY at the top of this file.');
  }
  if (!url || url.indexOf('PASTE_') === 0) {
    throw new Error('No Metabase URL. Set the METABASE_URL script property, ' +
                    'or fill METABASE_URL at the top of this file.');
  }
  return { key: key, url: url.replace(/\/+$/, '') };
}

/**
 * Overwrite the feed tab with a fresh run of card 57484.
 *
 * Uses the CSV endpoint, not JSON, deliberately: CSV preserves the card's
 * column ORDER, and this whole workbook addresses the feed positionally
 * (COLS = $A:$AV, period_start = $F). A JSON object's key order is not
 * guaranteed, so one reordered column would silently shift every lookup.
 */
function refreshFeed_() {
  var cfg = mbConfig_();
  var res = UrlFetchApp.fetch(
    cfg.url + '/api/card/' + CARD_ID + '/query/csv',
    { method: 'post',
      headers: { 'x-api-key': cfg.key },
      muteHttpExceptions: true });

  var code = res.getResponseCode();
  if (code !== 200) {
    throw new Error('Metabase returned ' + code + ' for card ' + CARD_ID + '. ' +
                    (code === 401 || code === 403
                       ? 'Check the API key and that its group can read the database.'
                       : res.getContentText().slice(0, 300)));
  }

  var rows = Utilities.parseCsv(res.getContentText());
  if (!rows.length || rows[0].length < 2) throw new Error('Card returned no columns.');

  var ss = SpreadsheetApp.getActive();
  var sh = ss.getSheetByName(FEED) || ss.insertSheet(FEED);
  sh.clear();

  // Formats BEFORE values, because Sheets coerces on write and the two
  // date-shaped columns need opposite treatment:
  //   F period_start -> a REAL date; every lookup key is rebuilt from it
  //   E period_label -> stay literal TEXT ('8/23/2026'), display only
  // Getting this backwards is the bug that blanked the MTD tab originally.
  var n = rows.length;
  sh.getRange(1, 5, n, 1).setNumberFormat('@');
  sh.getRange(1, 6, n, 1).setNumberFormat('yyyy-mm-dd');

  sh.getRange(1, 1, n, rows[0].length).setValues(rows);
  sh.setFrozenRows(1);
  return n - 1;   // data rows, excluding the header
}

/**
 * The autonomous entry point: refresh the feed, then rebuild every tab.
 * Point a time-driven trigger at THIS, not at buildReport.
 */
function refreshAndRebuild() {
  var n = refreshFeed_();
  buildReport();
  SpreadsheetApp.getActive().toast(n + ' feed rows pulled from card ' + CARD_ID, 'Refreshed', 8);
}

/**
 * Run ONCE to schedule refreshAndRebuild every weekday at 7am. Re-running is
 * safe — it clears its own previous trigger first rather than stacking.
 */
function installDailyTrigger() {
  ScriptApp.getProjectTriggers().forEach(function (t) {
    if (t.getHandlerFunction() === 'refreshAndRebuild') ScriptApp.deleteTrigger(t);
  });
  ScriptApp.newTrigger('refreshAndRebuild').timeBased().everyDays(1).atHour(7).create();
  SpreadsheetApp.getActive().toast('refreshAndRebuild scheduled daily at 7am', 'Trigger set', 8);
}

/** Verify credentials and connectivity without touching the sheet. */
function testMetabaseConnection() {
  var cfg = mbConfig_();
  var res = UrlFetchApp.fetch(cfg.url + '/api/card/' + CARD_ID,
    { headers: { 'x-api-key': cfg.key }, muteHttpExceptions: true });
  var msg = res.getResponseCode() === 200
    ? 'OK — card ' + CARD_ID + ' is "' + JSON.parse(res.getContentText()).name + '"'
    : 'FAILED ' + res.getResponseCode() + ': ' + res.getContentText().slice(0, 200);
  Logger.log(msg);
  SpreadsheetApp.getActive().toast(msg, 'Metabase', 10);
}

function colLetter_(n) {
  var s = '';
  while (n > 0) { var m = (n - 1) % 26; s = String.fromCharCode(65 + m) + s; n = (n - m - 1) / 26; }
  return s;
}
