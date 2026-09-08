/**
 * Josie Maran — Automated Reporting
 * Builds every tab, formula, number format and conditional format.
 *
 * RUN:  Extensions → Apps Script → paste this file → Save → Run ▸ buildReport
 * Idempotent. Never touches the feed tab, which the Metabase extension owns.
 *
 * ── THE FEED TAB NAME ───────────────────────────────────────────────────────
 * The Metabase extension appends the question id, so the tab is
 * `feed @ 57484`, not `feed`. That name contains spaces and an `@`, so every
 * formula has to quote it: 'feed @ 57484'!$A:$AV. FEED_REF below does that
 * once — if the question id ever changes, edit FEED and nothing else.
 *
 * ── FOUR CONVERSION SOURCES, NONE INTERCHANGEABLE ───────────────────────────
 * Column G (read_metrics) says which family applies to each row:
 *   paid_*  platform-attributed (Meta/Google own pixel, view-through window)
 *   ga4_*   GA4 last-non-direct session attribution
 *   cs_*    Sephora, via catalog segment actions
 *   site_*  what Shopify booked
 * paid_roas and ga4_roas WILL disagree. The DTC slides show both. Never add them.
 *
 * ── TAB SHAPES MIRROR THE DECK ──────────────────────────────────────────────
 * The slides fall into three shapes, so there are three grid tabs rather than
 * eight near-identical ones:
 *   DTC WoW              Paid DTC Overall / Meta Overall / Google Overall
 *                        — full funnel incl. GA4 ROAS
 *   Sephora Traffic WoW  US / CA Traffic + @ Kohls — delivery only, because
 *                        these campaigns emit no catalog-segment conversions
 *   Sephora Collab WoW   US / CA Collab — full funnel on cs_*
 * Plus MTD (month grain, every segment), GA4 Channels, Campaigns, Site,
 * Health, Config, README.
 */

var FEED     = 'feed @ 57484';                     // extension appends the question id
var FEED_REF = "'" + FEED + "'";                   // quoted for use in formulas
var COLS     = '$A:$AV';                           // 48 columns
var COL_KEY  = '$H:$H';                            // lookup_key
var COL_VALID = '$AS:$AS';                         // data_valid
var COL_FEEDBACK = '$AT:$AT';                      // has_catalog_feedback
var WEEKS = 8, MONTHS = 4;

var GRIDS = {
  'DTC WoW': {
    level: 'DTC Segment', grain: 'week', periods: WEEKS,
    rows: [
      ['Paid DTC Overall', 'All', 3.50],
      ['Meta Overall',     'All', 2.50],
      ['Google Overall',   'All', 10.00]
    ],
    blocks: [
      ['SPEND',          'spend',           '$#,##0'],
      ['CPM',            'cpm',             '$0.00'],
      ['CTR',            'ctr',             '0.00%'],
      ['CLICKS',         'clicks',          '#,##0'],
      ['CPC',            'cpc',             '$0.00'],
      ['CVR',            'paid_cvr',        '0.00%'],
      ['PURCHASES',      'paid_purchases',  '#,##0'],
      ['CPA',            'paid_cpa',        '$#,##0.00'],
      ['REVENUE',        'paid_revenue',    '$#,##0'],
      ['ROAS',           'paid_roas',       '0.00'],
      ['GA4 ROAS',       'ga4_roas',        '0.00'],
      ['AOV',            'paid_aov',        '$#,##0.00']
    ],
    flagCol: COL_VALID, flagStyle: 'grey',
    flagBlocks: ['GA4 ROAS', 'REVENUE', 'ROAS', 'PURCHASES', 'CPA', 'CVR', 'AOV']
  },
  'Sephora Traffic WoW': {
    level: 'Sephora Segment', grain: 'week', periods: WEEKS,
    rows: [
      ['Sephora US Traffic', 'All', ''],
      ['Sephora CA Traffic', 'All', ''],
      ['Sephora @ Kohls',    'All', '']
    ],
    // Delivery only, on purpose. These campaigns emit no catalog-segment rows,
    // so there is no honest conversion number to put on the slide.
    blocks: [
      ['SPEND',  'spend',  '$#,##0'],
      ['CPM',    'cpm',    '$0.00'],
      ['CTR',    'ctr',    '0.00%'],
      ['CLICKS', 'clicks', '#,##0'],
      ['CPC',    'cpc',    '$0.00']
    ],
    flagCol: COL_FEEDBACK, flagStyle: 'amber', flagBlocks: []
  },
  'Sephora Collab WoW': {
    level: 'Sephora Segment', grain: 'week', periods: WEEKS,
    rows: [
      ['Sephora US Collab', 'All', 1.50],
      ['Sephora CA Collab', 'All', 2.50],
      ['Sephora – Total',   'All', '']
    ],
    blocks: [
      ['SPEND',        'spend',        '$#,##0'],
      ['CPM',          'cpm',          '$0.00'],
      ['CTR',          'ctr',          '0.00%'],
      ['CPC',          'cpc',          '$0.00'],
      ['CVR',          'cs_cvr',       '0.00%'],
      ['PURCHASES',    'cs_purchases', '#,##0'],
      ['CPA',          'cs_cpa',       '$#,##0.00'],
      ['REVENUE',      'cs_revenue',   '$#,##0'],
      ['ROAS',         'cs_roas',      '0.00'],
      ['AOV',          'cs_aov',       '$#,##0.00'],
      ['% IN STORE',   'pct_instore',  '0.0%']
    ],
    flagCol: COL_FEEDBACK, flagStyle: 'amber',
    flagBlocks: ['CVR', 'PURCHASES', 'CPA', 'REVENUE', 'ROAS', 'AOV', '% IN STORE']
  },
  'Site': {
    level: 'Site', grain: 'week', periods: WEEKS,
    rows: [
      ['All', 'All', ''], ['Web', 'All', ''], ['Subscription', 'All', ''],
      ['All', 'US', ''],  ['All', 'CA', '']
    ],
    blocks: [
      ['ORDERS',        'site_orders',        '#,##0'],
      ['FIRST ORDERS',  'site_first_orders',  '#,##0'],
      ['NEW CUSTOMERS', 'site_new_customers', '#,##0'],
      ['GROSS SALES',   'site_gross_sales',   '$#,##0'],
      ['AOV',           'aov',                '$#,##0.00'],
      ['% NEW ORDERS',  'pct_new',            '0.0%']
    ],
    flagCol: COL_VALID, flagStyle: 'grey', flagBlocks: []
  },
  'GA4 Channels': {
    level: 'GA4 Channel', grain: 'week', periods: WEEKS,
    // The GA4 revenue that attached to no paid campaign. 'Other' is email, SMS,
    // organic, direct, affiliates. 'Unattributed Paid' is paid sessions whose
    // campaign could not be resolved — watch it on the Health tab.
    rows: [
      ['Other',             'All', ''],
      ['Unattributed Paid', 'All', '']
    ],
    blocks: [
      ['SESSIONS',  'ga4_sessions',  '#,##0'],
      ['PURCHASES', 'ga4_purchases', '#,##0'],
      ['REVENUE',   'ga4_revenue',   '$#,##0'],
      ['CVR',       'ga4_cvr',       '0.00%'],
      ['AOV',       'ga4_aov',       '$#,##0.00']
    ],
    flagCol: COL_VALID, flagStyle: 'grey', flagBlocks: []
  }
};

// Month grain — the "September MTD" block that every slide carries.
var MTD = {
  level: null, grain: 'month', periods: MONTHS,
  rows: [
    ['Paid DTC Overall',   'All', 'DTC Segment'],
    ['Meta Overall',       'All', 'DTC Segment'],
    ['Google Overall',     'All', 'DTC Segment'],
    ['Sephora – Total',    'All', 'Sephora Segment'],
    ['Sephora US Traffic', 'All', 'Sephora Segment'],
    ['Sephora CA Traffic', 'All', 'Sephora Segment'],
    ['Sephora @ Kohls',    'All', 'Sephora Segment'],
    ['Sephora US Collab',  'All', 'Sephora Segment'],
    ['Sephora CA Collab',  'All', 'Sephora Segment'],
    ['All',                'All', 'Site']
  ],
  blocks: [
    ['SPEND',        'spend',        '$#,##0'],
    ['CTR',          'ctr',          '0.00%'],
    ['CPC',          'cpc',          '$0.00'],
    ['PAID CVR',     'paid_cvr',     '0.00%'],
    ['PAID REVENUE', 'paid_revenue', '$#,##0'],
    ['PAID ROAS',    'paid_roas',    '0.00'],
    ['GA4 ROAS',     'ga4_roas',     '0.00'],
    ['CS PURCHASES', 'cs_purchases', '#,##0'],
    ['CS ROAS',      'cs_roas',      '0.00'],
    ['SITE ORDERS',  'site_orders',  '#,##0'],
    ['AOV',          'paid_aov',     '$#,##0.00']
  ]
};

var C = {
  header:'#14201e', headerT:'#f6f5f0', block:'#efede5', rule:'#dfdcd1',
  amber:'#f4e9cf', amberT:'#8a6412', grey:'#eeeeee', greyT:'#999999', note:'#66756f'
};

function buildReport() {
  var ss = SpreadsheetApp.getActive();
  ensureFeedTab_(ss);
  writeReadme_(ss);
  Object.keys(GRIDS).forEach(function (n) { buildGrid_(ss, n, GRIDS[n]); });
  buildMtd_(ss);
  buildCampaigns_(ss);
  buildHealth_(ss);
  orderTabs_(ss);
  ss.toast('Rebuilt. Feed tab expected: "' + FEED + '"', 'Done', 8);
}

// ── helpers ────────────────────────────────────────────────────────────────

function sheet_(ss, name, wipe) {
  var sh = ss.getSheetByName(name);
  if (!sh) sh = ss.insertSheet(name);
  else if (wipe) { sh.clear(); sh.clearConditionalFormatRules(); }
  return sh;
}

function ensureFeedTab_(ss) {
  if (ss.getSheetByName(FEED)) return;
  // The extension creates it. If a bare `feed` exists from an earlier setup,
  // say so rather than silently building grids that resolve to nothing.
  var bare = ss.getSheetByName('feed');
  var sh = ss.insertSheet(FEED);
  sh.getRange('A1').setValue(
    'Connect the Metabase question "JM – Reporting Feed" (57484) to this tab. ' +
    'Header row in row 1, 48 columns A:AV. Do not edit by hand.' +
    (bare ? '  NOTE: a tab named "feed" also exists — the extension names it ' +
            '"feed @ 57484", so the old one is stale and can be deleted.' : ''));
  sh.getRange('A1').setFontColor(C.note).setFontStyle('italic').setWrap(true);
}

/** One metric for one row/period. Row by lookup_key, column BY HEADER NAME. */
function cell_(level, rowRef, mktRef, periodRef, metric) {
  return '=IFERROR(INDEX(' + FEED_REF + '!' + COLS + ',' +
         ' MATCH("' + level + '|"&' + rowRef + '&"|"&' + mktRef + '&"|"&' + periodRef + ',' +
         ' ' + FEED_REF + '!' + COL_KEY + ', 0),' +
         ' MATCH("' + metric + '", ' + FEED_REF + '!$1:$1, 0)), "")';
}

function periodHeader_(level, grain, idx) {
  return '=IFERROR(INDEX(SORT(UNIQUE(FILTER(' + FEED_REF + '!$E:$E,' +
         ' ' + FEED_REF + '!$A:$A="' + level + '", ' + FEED_REF + '!$D:$D="' + grain + '",' +
         ' ' + FEED_REF + '!$E:$E<>"")),1,FALSE), ' + idx + '), "")';
}

// ── grids ──────────────────────────────────────────────────────────────────

function buildGrid_(ss, name, cfg) {
  var avgSpan = cfg.grain === 'week' ? 4 : 3;
  var n = cfg.periods, lastCol = 1 + n + 2;
  var sh = sheet_(ss, name, true);

  sh.getRange(1, 1).setValue(name).setFontSize(14).setFontWeight('bold').setFontColor(C.headerT);
  sh.getRange(1, 1, 1, lastCol).setBackground(C.header);
  sh.getRange('A2').setValue('Data through:');
  sh.getRange('B2').setFormula('=IFERROR(TEXT(MAX(FILTER(' + FEED_REF + '!$F:$F, ' +
    FEED_REF + '!$A:$A="' + cfg.level + '")),"yyyy-mm-dd"),"— connect feed —")');
  sh.getRange('A3').setValue('Health:');
  sh.getRange('B3').setFormula('=COUNTIF(' + FEED_REF + '!$AU:$AU,"FAIL")&" checks failing"');
  sh.getRange('A2:A3').setFontColor(C.note);
  sh.getRange('B3').setFontColor(C.amberT);

  var row = 5;
  cfg.blocks.forEach(function (blk) {
    var label = blk[0], metric = blk[1], fmt = blk[2];
    sh.getRange(row, 1, 1, lastCol).setBackground(C.block);
    sh.getRange(row, 1).setValue(label + '   ·   ' + metric).setFontWeight('bold').setFontSize(9);
    row++;

    sh.getRange(row, 1).setValue('Segment').setFontWeight('bold');
    for (var p = 0; p < n; p++) sh.getRange(row, 2 + p).setFormula(periodHeader_(cfg.level, cfg.grain, p + 1));
    sh.getRange(row, 2 + n).setValue(cfg.grain === 'week' ? 'WoW %' : 'MoM %');
    sh.getRange(row, 3 + n).setValue(avgSpan + (cfg.grain === 'week' ? 'wk avg' : 'mo avg'));
    sh.getRange(row, 1, 1, lastCol).setFontWeight('bold').setBackground(C.block);
    var hdr = row; row++;

    var first = row;
    cfg.rows.forEach(function (r) {
      sh.getRange(row, 1).setValue(r[0] + (r[1] !== 'All' ? '  (' + r[1] + ')' : ''));
      for (var p = 0; p < n; p++) {
        sh.getRange(row, 2 + p).setFormula(
          cell_(cfg.level, '"' + r[0] + '"', '"' + r[1] + '"', colLetter_(2 + p) + '$' + hdr, metric));
      }
      var c1 = colLetter_(2), c2 = colLetter_(3), cA = colLetter_(2 + avgSpan);
      sh.getRange(row, 2 + n).setFormula('=IFERROR(IF(' + c2 + row + '=0,"",' + c1 + row + '/' + c2 + row + '-1),"")');
      sh.getRange(row, 3 + n).setFormula('=IFERROR(AVERAGE(' + c2 + row + ':' + cA + row + '),"")');
      row++;
    });

    sh.getRange(first, 2, cfg.rows.length, n).setNumberFormat(fmt);
    sh.getRange(first, 2 + n, cfg.rows.length, 1).setNumberFormat('+0.0%;-0.0%;0.0%');
    sh.getRange(first, 3 + n, cfg.rows.length, 1).setNumberFormat(fmt);

    if (cfg.flagCol && cfg.flagBlocks.indexOf(label) >= 0) addFlagRule_(sh, cfg, first, hdr, n);
    row++;
  });

  var noteRow = row + 1;
  var t = cfg.rows.filter(function (r) { return r[2] !== ''; })
                  .map(function (r) { return r[0] + ' ≥ ' + r[2]; });
  if (t.length) sh.getRange(noteRow, 1).setValue('Targets:  ' + t.join('   ·   '))
                  .setFontColor(C.note).setFontSize(9);
  sh.getRange(noteRow + 1, 1).setValue(
    cfg.flagStyle === 'amber'
      ? 'Amber = real Sephora spend with conversions unreported (no catalog-segment feedback). Act on it.'
      : 'Grey = the underlying data does not exist for that period. Ignore; do not backfill.')
    .setFontColor(C.note).setFontSize(9);

  sh.setColumnWidth(1, 200);
  for (var c = 2; c <= lastCol; c++) sh.setColumnWidth(c, 92);
  sh.setFrozenRows(1); sh.setFrozenColumns(1);
}

/** The flag formula is anchored at the range's top-left, so $A<first> walks
 *  down per row and B$<hdr> walks across per column — one rule covers the block.
 *  Market is hardcoded '|All|' because every flagged grid row is market All. */
function addFlagRule_(sh, cfg, first, hdr, n) {
  var rng = sh.getRange(first, 2, cfg.rows.length, n);
  var rule = SpreadsheetApp.newConditionalFormatRule()
    .whenFormulaSatisfied(
      '=IFERROR(INDEX(' + FEED_REF + '!' + cfg.flagCol + ',' +
      ' MATCH("' + cfg.level + '|"&$A' + first + '&"|All|"&' + colLetter_(2) + '$' + hdr + ',' +
      ' ' + FEED_REF + '!' + COL_KEY + ', 0))=FALSE, FALSE)')
    .setBackground(cfg.flagStyle === 'amber' ? C.amber : C.grey)
    .setFontColor(cfg.flagStyle === 'amber' ? C.amberT : C.greyT)
    .setRanges([rng]).build();
  var rules = sh.getConditionalFormatRules(); rules.push(rule);
  sh.setConditionalFormatRules(rules);
}

/** MTD spans levels, so each row carries its own level. */
function buildMtd_(ss) {
  var n = MTD.periods, lastCol = 1 + n + 2;
  var sh = sheet_(ss, 'MTD', true);
  sh.getRange(1, 1).setValue('MTD  ·  month grain').setFontSize(14).setFontWeight('bold').setFontColor(C.headerT);
  sh.getRange(1, 1, 1, lastCol).setBackground(C.header);
  sh.getRange('A2').setValue('The September MTD block on every slide. Read column G on the feed for which metric family applies.')
    .setFontColor(C.note).setFontSize(9);

  var row = 4;
  MTD.blocks.forEach(function (blk) {
    var label = blk[0], metric = blk[1], fmt = blk[2];
    sh.getRange(row, 1, 1, lastCol).setBackground(C.block);
    sh.getRange(row, 1).setValue(label + '   ·   ' + metric).setFontWeight('bold').setFontSize(9);
    row++;
    sh.getRange(row, 1).setValue('Segment').setFontWeight('bold');
    // month labels: any level will do, they share the period list
    for (var p = 0; p < n; p++) sh.getRange(row, 2 + p).setFormula(periodHeader_('DTC Segment', 'month', p + 1));
    sh.getRange(row, 2 + n).setValue('MoM %');
    sh.getRange(row, 3 + n).setValue('3mo avg');
    sh.getRange(row, 1, 1, lastCol).setFontWeight('bold').setBackground(C.block);
    var hdr = row; row++;
    var first = row;
    MTD.rows.forEach(function (r) {
      sh.getRange(row, 1).setValue(r[0]);
      for (var p = 0; p < n; p++) {
        sh.getRange(row, 2 + p).setFormula(
          cell_(r[2], '"' + r[0] + '"', '"' + r[1] + '"', colLetter_(2 + p) + '$' + hdr, metric));
      }
      var c1 = colLetter_(2), c2 = colLetter_(3), cA = colLetter_(4);
      sh.getRange(row, 2 + n).setFormula('=IFERROR(IF(' + c2 + row + '=0,"",' + c1 + row + '/' + c2 + row + '-1),"")');
      sh.getRange(row, 3 + n).setFormula('=IFERROR(AVERAGE(' + c2 + row + ':' + cA + row + '),"")');
      row++;
    });
    sh.getRange(first, 2, MTD.rows.length, n).setNumberFormat(fmt);
    sh.getRange(first, 2 + n, MTD.rows.length, 1).setNumberFormat('+0.0%;-0.0%;0.0%');
    sh.getRange(first, 3 + n, MTD.rows.length, 1).setNumberFormat(fmt);
    row++;
  });
  sh.setColumnWidth(1, 200);
  for (var c = 2; c <= lastCol; c++) sh.setColumnWidth(c, 92);
  sh.setFrozenRows(1); sh.setFrozenColumns(1);
}

// ── QUERY tabs ─────────────────────────────────────────────────────────────

function buildCampaigns_(ss) {
  var sh = sheet_(ss, 'Campaigns', true);
  sh.getRange('A1').setValue('Campaigns').setFontSize(14).setFontWeight('bold').setFontColor(C.headerT);
  sh.getRange('A1:L1').setBackground(C.header);
  sh.getRange('A2').setValue('Week:');
  sh.getRange('B2').setFormula('=IFERROR(INDEX(SORT(UNIQUE(FILTER(' + FEED_REF + '!$E:$E, ' +
    FEED_REF + '!$A:$A="Campaign", ' + FEED_REF + '!$D:$D="week", ' + FEED_REF + '!$E:$E<>"")),1,FALSE),1),"")');
  sh.getRange('A3').setValue('read_metrics says which family applies: Sephora rows use cs_*, DTC rows use paid_*.')
    .setFontColor(C.note).setFontSize(9);
  sh.getRange('A5').setFormula(
    '=IFERROR(QUERY(' + FEED_REF + '!' + COLS + ',' +
    ' "select B, C, G, I, O, Q, X, AB, AD' +
    '   where A = \'Campaign\' and D = \'week\' and E = \'"&$B$2&"\'' +
    '   order by I desc' +
    '   label B \'Campaign\', C \'Market\', G \'Read\', I \'Spend\', O \'Paid purch\',' +
    ' Q \'Paid ROAS\', X \'GA4 ROAS\', AB \'cs purch\', AD \'cs ROAS\'", 1),' +
    ' "No campaign rows — check the feed tab name is exactly: ' + FEED + '")');
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
    ' "No health rows — check the feed tab name is exactly: ' + FEED + '")');
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
    ['FEED TAB: "' + FEED + '"  — the Metabase extension appends the question id.'],
    ['One question (57484), 48 columns A:AV. Never edit, sort or format that tab.'],
    [''],
    ['FOUR CONVERSION SOURCES. CHECK COLUMN G (read_metrics) BEFORE READING A NUMBER.'],
    ['  paid_*  what Meta/Google claim on their own pixel, with a view-through window'],
    ['  ga4_*   GA4 last-non-direct session attribution, by session source/medium'],
    ['  cs_*    Sephora, via catalog segment actions — the ONLY place Sephora converts'],
    ['  site_*  what Shopify actually booked'],
    ['paid_roas and ga4_roas will disagree. The DTC slides show both. Never add them.'],
    [''],
    ['GA4 CHANNEL MAPPING'],
    ['  metaads / paidsocial -> Meta      google / cpc -> Google      else -> Other'],
    ['TikTok has no mapping yet — no DTC TikTok campaigns exist, so no source/medium'],
    ['to claim. Google\'s session_campaign_id is the campaign id; Meta\'s is'],
    ['<adset_id>_v2_sNN, so it needs the adset->campaign lookup (99.2% resolves).'],
    ['GA4 that attaches to no campaign lands on the GA4 Channels tab as "Other" or'],
    ['"Unattributed Paid" — so total GA4 revenue reconciles instead of disappearing.'],
    [''],
    ['SEPHORA TRAFFIC HAS NO CONVERSION NUMBERS, AND THAT IS NOT AN OMISSION.'],
    ['US/CA Traffic and @ Kohls emit no catalog-segment rows, so there is no honest'],
    ['Sephora purchase figure for them. The tab shows delivery only. Amber cells mean'],
    ['real spend with conversions unreported — act on it, do not fill it in.'],
    ['Collab does report: US Collab 4.82 ROAS, CA Collab 4.64 in the week of 8/31,'],
    ['on 5% of Sephora spend and all 145 measured purchases.'],
    [''],
    ['SEGMENTS COME FROM CAMPAIGN IDS, NOT NAMES.'],
    ['seeds/campaign_segments.csv in bolt-josiemaran, taken from the reporting deck.'],
    ['The account was inherited and carries three naming conventions, one objective'],
    ['spelled three ways, and region as us/US/ca/CA/USA — names were never a safe key.'],
    ['An unmapped campaign id gets segment "Unmapped", appears on NO segment row, and'],
    ['is reported on the Health tab. When a campaign launches, add its id to the CSV.'],
    [''],
    ['GREY = DTC BLENDED METRICS START THE WEEK OF 2026-07-27.'],
    ['Shopify order history begins there: 19 orders the week before, 2,737 that week.'],
    ['August 2026 is the only complete month, so no blended MoM until October and no'],
    ['blended YoY this year. Sephora is the opposite: catalog-segment history from'],
    ['2025-03. GA4 goes back to 2024-08-17.'],
    [''],
    ['GOOGLE ADS RUNS ~8 DAYS BEHIND Meta and Shopify. Check the Health tab before'],
    ['comparing Google to another channel in the current week. Its ~1,100% ROAS is'],
    ['correct — branded search is run to a deliberate 1,000% tROAS.'],
    [''],
    ['21% OF DTC ORDERS ARE SUBSCRIPTION RENEWALS and 78% are repeat purchases, so'],
    ['site revenue moves largely independently of this week\'s spend. Judge paid on'],
    ['new-customer CAC and % new orders.'],
    [''],
    ['TO REBUILD: Extensions -> Apps Script -> Run buildReport. Row order and targets'],
    ['live in the GRIDS object at the top of the script.']
  ];
  sh.getRange(1, 1, L.length, 1).setValues(L);
  sh.getRange(1, 1).setFontSize(14).setFontWeight('bold');
  [3, 6, 13, 21, 28, 35, 41, 45, 49].forEach(function (r) { sh.getRange(r, 1).setFontWeight('bold'); });
  sh.setColumnWidth(1, 800);
  sh.getRange(1, 1, L.length, 1).setVerticalAlignment('top');
}

function orderTabs_(ss) {
  ['README','Health','DTC WoW','MTD','Sephora Traffic WoW','Sephora Collab WoW',
   'GA4 Channels','Site','Campaigns', FEED].forEach(function (n, i) {
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
