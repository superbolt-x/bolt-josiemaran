/**
 * Josie Maran — Automated Reporting
 * RUN: Extensions → Apps Script → paste → Save → Run ▸ buildReport
 * Idempotent. Never touches the feed tab, which the Metabase extension owns.
 *
 * ── LAYOUT MIRRORS THE DECK, NOT A GENERIC GRID ─────────────────────────────
 * Each slide carries a WoW table with metrics down the rows and exactly TWO
 * date columns plus % change, and a "Spend vs ROAS" chart. So that is what
 * this builds: one KPI block per segment, metrics as rows, 2 periods + delta,
 * followed by a 4-period chart-data block the Sheets chart points at.
 *
 * The feed supplies 7 weeks and 3 months. The KPI block reads the last 2 and
 * the chart block the last 4 — the filtering happens here, not in the card, so
 * changing the report window never means editing SQL.
 *
 * ── FEED TAB ────────────────────────────────────────────────────────────────
 * The extension appends the question id, so the tab is `feed @ 57484`. The name
 * has a space and an `@`, so it has to be quoted in every formula. FEED_REF
 * does that once — change FEED if the question id changes, nothing else.
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
var KEY      = '$H:$H';         // lookup_key
var VALID    = '$AS:$AS';       // data_valid
var FEEDBACK = '$AT:$AT';       // has_catalog_feedback

var KPI_PERIODS   = 2;          // the slide's WoW table
var CHART_PERIODS = 4;          // the slide's chart

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

// One entry per slide. `level` + `row` + `market` build the lookup key.
var TABS = {
  'DTC WoW': { shape: 'dtc', grain: 'week', slides: [
    ['Paid DTC Overall', 'DTC Segment', 'All', 3.50],
    ['Meta Overall',     'DTC Segment', 'All', 2.50],
    ['Google Overall',   'DTC Segment', 'All', 10.00]
  ]},
  'Sephora Traffic WoW': { shape: 'sephoraTraffic', grain: 'week', slides: [
    ['Sephora US Traffic', 'Sephora Segment', 'All', ''],
    ['Sephora CA Traffic', 'Sephora Segment', 'All', ''],
    ['Sephora @ Kohls',    'Sephora Segment', 'All', '']
  ]},
  'Sephora Collab WoW': { shape: 'sephoraCollab', grain: 'week', slides: [
    ['Sephora US Collab', 'Sephora Segment', 'All', 1.50],
    ['Sephora CA Collab', 'Sephora Segment', 'All', 2.50],
    ['Sephora – Total',   'Sephora Segment', 'All', '']
  ]},
  'Site': { shape: 'site', grain: 'week', slides: [
    ['All',          'Site', 'All', ''],
    ['Web',          'Site', 'All', ''],
    ['Subscription', 'Site', 'All', '']
  ]},
  'GA4 Channels': { shape: 'ga4', grain: 'week', slides: [
    ['Other',             'GA4 Channel', 'All', ''],
    ['Unattributed Paid', 'GA4 Channel', 'All', '']
  ]},
  'MTD': { shape: 'dtc', grain: 'month', slides: [
    ['Paid DTC Overall', 'DTC Segment', 'All', ''],
    ['Meta Overall',     'DTC Segment', 'All', ''],
    ['Google Overall',   'DTC Segment', 'All', '']
  ]},
  'MTD Sephora': { shape: 'sephoraCollab', grain: 'month', slides: [
    ['Sephora – Total',   'Sephora Segment', 'All', ''],
    ['Sephora US Collab', 'Sephora Segment', 'All', ''],
    ['Sephora CA Collab', 'Sephora Segment', 'All', '']
  ]}
};

var C = { header:'#14201e', headerT:'#f6f5f0', block:'#efede5', amber:'#f4e9cf',
          amberT:'#8a6412', grey:'#eeeeee', greyT:'#999999', note:'#66756f' };

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
  else if (wipe) { sh.clear(); sh.clearConditionalFormatRules(); }
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
 * Period label, counted back from the newest the feed holds.
 * offset 0 = newest. The feed carries 7 weeks / 3 months; the KPI block asks
 * for 2 and the chart for 4, so the window lives here rather than in the SQL.
 */
function periodAt_(level, grain, offsetFromNewest) {
  return '=IFERROR(INDEX(SORT(UNIQUE(FILTER(' + FEED_REF + '!$E:$E,' +
         ' ' + FEED_REF + '!$A:$A="' + level + '", ' + FEED_REF + '!$D:$D="' + grain + '",' +
         ' ' + FEED_REF + '!$E:$E<>"")),1,FALSE), ' + (offsetFromNewest + 1) + '), "")';
}

/** One metric for one row/period. Row by lookup_key, metric BY HEADER NAME. */
function cell_(level, row, market, periodRef, metric) {
  return '=IFERROR(INDEX(' + FEED_REF + '!' + COLS + ',' +
         ' MATCH("' + level + '|' + row + '|' + market + '|"&' + periodRef + ',' +
         ' ' + FEED_REF + '!' + KEY + ', 0),' +
         ' MATCH("' + metric + '", ' + FEED_REF + '!$1:$1, 0)), "")';
}

function buildTab_(ss, name, cfg) {
  var shape = SHAPES[cfg.shape];
  var sh = sheet_(ss, name, true);
  var isWeek = cfg.grain === 'week';

  sh.getRange(1, 1).setValue(name).setFontSize(14).setFontWeight('bold').setFontColor(C.headerT);
  sh.getRange(1, 1, 1, 5).setBackground(C.header);
  sh.getRange('A2').setValue('Data through:');
  sh.getRange('B2').setFormula('=IFERROR(TEXT(MAX(FILTER(' + FEED_REF + '!$F:$F, ' +
    FEED_REF + '!$A:$A="' + cfg.slides[0][1] + '", ' + FEED_REF + '!$D:$D="' + cfg.grain +
    '")),"yyyy-mm-dd"),"— connect feed —")');
  sh.getRange('A3').setValue('Health:');
  sh.getRange('B3').setFormula('=COUNTIF(' + FEED_REF + '!$AU:$AU,"FAIL")&" checks failing"')
    .setFontColor(C.amberT);
  sh.getRange('A2:A3').setFontColor(C.note);

  var row = 5;
  cfg.slides.forEach(function (sl) {
    var label = sl[0], level = sl[1], market = sl[2], target = sl[3];

    // ── slide title ────────────────────────────────────────────────────────
    sh.getRange(row, 1, 1, 4).setBackground(C.block);
    sh.getRange(row, 1).setValue(label + (target !== '' ? '     target ROAS ≥ ' + target : ''))
      .setFontWeight('bold');
    row++;

    // ── KPI table: metrics as rows, oldest→newest, then % change ───────────
    var hdr = row;
    sh.getRange(row, 1).setValue('Date').setFontWeight('bold');
    for (var k = KPI_PERIODS - 1; k >= 0; k--) {
      sh.getRange(row, 1 + (KPI_PERIODS - k)).setFormula(periodAt_(level, cfg.grain, k));
    }
    sh.getRange(row, 2 + KPI_PERIODS).setValue('% change').setFontWeight('bold');
    sh.getRange(row, 1, 1, 2 + KPI_PERIODS).setFontWeight('bold').setBackground(C.block);
    row++;

    var first = row;
    shape.metrics.forEach(function (m) {
      sh.getRange(row, 1).setValue(m[0]);
      for (var k = KPI_PERIODS - 1; k >= 0; k--) {
        var col = 1 + (KPI_PERIODS - k);
        sh.getRange(row, col).setFormula(
          cell_(level, label, market, colLetter_(col) + '$' + hdr, m[1]))
          .setNumberFormat(m[2]);
      }
      var older = colLetter_(2), newer = colLetter_(1 + KPI_PERIODS);
      sh.getRange(row, 2 + KPI_PERIODS)
        .setFormula('=IFERROR(IF(' + older + row + '=0,"",' + newer + row + '/' + older + row + '-1),"")')
        .setNumberFormat('+0.0%;-0.0%;0.0%');
      row++;
    });
    if (shape.flag) addFlagRule_(sh, shape, level, label, first, shape.metrics.length, hdr);
    row++;

    // ── chart data: CHART_PERIODS periods, oldest → newest ─────────────────
    sh.getRange(row, 1).setValue('Chart data  ·  ' + CHART_PERIODS +
      (isWeek ? ' weeks' : ' months')).setFontSize(9).setFontColor(C.note);
    row++;
    var chdr = row;
    sh.getRange(row, 1).setValue(isWeek ? 'Week' : 'Month').setFontWeight('bold');
    shape.chart.forEach(function (m, i) { sh.getRange(row, 2 + i).setValue(m[0]).setFontWeight('bold'); });
    row++;
    for (var k = CHART_PERIODS - 1; k >= 0; k--) {
      sh.getRange(row, 1).setFormula(periodAt_(level, cfg.grain, k));
      shape.chart.forEach(function (m, i) {
        sh.getRange(row, 2 + i)
          .setFormula(cell_(level, label, market, '$A' + row, m[1]))
          .setNumberFormat(m[2]);
      });
      row++;
    }
    sh.getRange(chdr, 1, 1 + CHART_PERIODS, 1 + shape.chart.length).setBorder(true, true, true, true, true, true);
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
}

/** Anchored at the range top-left: $A<first> walks down, B$<hdr> walks across. */
function addFlagRule_(sh, shape, level, label, first, nRows, hdr) {
  var rng = sh.getRange(first, 2, nRows, KPI_PERIODS);
  var rule = SpreadsheetApp.newConditionalFormatRule()
    .whenFormulaSatisfied(
      '=IFERROR(INDEX(' + FEED_REF + '!' + shape.flag + ',' +
      ' MATCH("' + level + '|' + label + '|All|"&' + colLetter_(2) + '$' + hdr + ',' +
      ' ' + FEED_REF + '!' + KEY + ', 0))=FALSE, FALSE)')
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
  sh.getRange('B2').setFormula(periodAt_('Campaign', 'week', 0));
  sh.getRange('A3').setValue('read_metrics says which family applies: Sephora rows use cs_*, DTC rows use paid_*.')
    .setFontColor(C.note).setFontSize(9);
  sh.getRange('A5').setFormula(
    '=IFERROR(QUERY(' + FEED_REF + '!' + COLS + ',' +
    ' "select B, C, G, I, O, Q, X, AB, AD' +
    '   where A = \'Campaign\' and D = \'week\' and E = \'"&$B$2&"\'' +
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
    ['two date columns plus % change, then a ' + CHART_PERIODS + '-period chart-data table.'],
    ['The feed carries 7 weeks and 3 months; the window is applied here, so'],
    ['changing it never means editing SQL.'],
    [''],
    ['FOUR CONVERSION SOURCES. CHECK COLUMN G (read_metrics) FIRST.'],
    ['  paid_*  Meta/Google own pixel, with a view-through window'],
    ['  ga4_*   GA4 last-non-direct session attribution'],
    ['  cs_*    Sephora, via catalog segment actions — the ONLY place it converts'],
    ['  site_*  what Shopify actually booked'],
    ['paid_roas and ga4_roas will disagree. The DTC slides show both. Never add them.'],
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
    ['GOOGLE ADS RUNS ~8 DAYS BEHIND. Its ~1,100% ROAS is correct — branded search'],
    ['is run to a deliberate 1,000% tROAS.'],
    [''],
    ['TO REBUILD: Extensions -> Apps Script -> Run buildReport. Metric sets live in'],
    ['SHAPES, slides in TABS, and the window in KPI_PERIODS / CHART_PERIODS.']
  ];
  sh.getRange(1, 1, L.length, 1).setValues(L);
  sh.getRange(1, 1).setFontSize(14).setFontWeight('bold');
  [3, 6, 11, 18, 22, 30, 36, 40, 44, 47].forEach(function (r) { sh.getRange(r, 1).setFontWeight('bold'); });
  sh.setColumnWidth(1, 800);
  sh.getRange(1, 1, L.length, 1).setVerticalAlignment('top');
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
