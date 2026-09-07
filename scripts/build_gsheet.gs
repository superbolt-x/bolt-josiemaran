/**
 * Josie Maran — Automated Reporting
 * Builds every tab, formula, conditional format and dropdown in the sheet.
 *
 * ── HOW TO RUN ──────────────────────────────────────────────────────────────
 *   1. Open the sheet → Extensions → Apps Script
 *   2. Delete the placeholder `myFunction`, paste this whole file, Save
 *   3. Run ▸ buildReport   (authorise when prompted — it only touches this file)
 *
 * Idempotent: safe to re-run. It rebuilds the report tabs from scratch every
 * time but NEVER touches the `feed` tab, which the Metabase extension owns.
 *
 * ── WHAT IT ASSUMES ─────────────────────────────────────────────────────────
 * A tab named `feed`, written by the Metabase extension from the question
 * "JM – Reporting Feed", with its header row in row 1 and these columns:
 *
 *   A report_level   E period_label   H lookup_key   AI data_valid
 *   B row_label      F period_start                  AJ has_catalog_feedback
 *   C market         G read_metrics                  AK status
 *   D grain                                          AL detail
 *
 * Metrics are found BY HEADER NAME, not by column letter, so adding or
 * reordering a metric column in the Metabase question will not break the grids.
 */

var FEED = 'feed';
var WEEKS = 8;          // week columns per grid
var MONTHS = 12;        // month columns on the Monthly tab

/** Rows for each grid: [row_label, market, target]  — order here is display order. */
var CONFIG = {
  'Sephora WoW': {
    level: 'Sephora Segment',
    rows: [
      ['Sephora – Total', 'All', ''],
      ['US Collab',       'All', 1.50],
      ['CA Collab',       'All', 2.50],
      ['US Traffic',      'All', ''],
      ['CA Traffic',      'All', ''],
      ['Kohls Traffic',   'All', ''],
      ['US ATC',          'All', ''],
      ['CA ATC',          'All', ''],
      ['US Engagement',   'All', '']
    ],
    // Sephora converts on Sephora's pixel: cs_* only. No paid_roas, no blended.
    blocks: [
      ['SPEND',              'spend',                '$#,##0'],
      ['SEPHORA PURCHASES',  'cs_purchases',         '#,##0'],
      ['SEPHORA REVENUE',    'cs_revenue',           '$#,##0'],
      ['SEPHORA ROAS',       'cs_roas',              '0.00'],
      ['SEPHORA CPA',        'cs_cpa',               '$#,##0.00'],
      ['% IN STORE',         'pct_instore',          '0.0%'],
      ['CPC',                'cpc',                  '$0.00'],
      ['CTR',                'ctr',                  '0.00%']
    ],
    flagCol: 'AJ',   // has_catalog_feedback → amber
    flagStyle: 'amber',
    flagBlocks: ['SEPHORA PURCHASES', 'SEPHORA REVENUE', 'SEPHORA ROAS', 'SEPHORA CPA', '% IN STORE']
  },
  'DTC WoW': {
    level: 'DTC Channel',
    rows: [
      ['Blended DTC',     'All', 3.50],
      ['Meta',            'All', 2.50],
      ['Google',          'All', 10.00],
      ['Shopify',         'All', ''],
      ['DTC ASC',         'All', ''],
      ['DTC Prospecting', 'All', ''],
      ['DTC Retargeting', 'All', ''],
      ['DTC Lifecycle',   'All', '']
    ],
    blocks: [
      ['SPEND',            'spend',              '$#,##0'],
      ['PAID PURCHASES',   'paid_purchases',     '#,##0'],
      ['PAID ROAS',        'paid_roas',          '0.00'],
      ['PAID CPA',         'paid_cpa',           '$#,##0.00'],
      ['SITE ORDERS',      'site_orders',        '#,##0'],
      ['NEW CUSTOMERS',    'site_new_customers', '#,##0'],
      ['BLENDED CAC',      'blended_cac',        '$#,##0.00'],
      ['BLENDED ROAS',     'blended_roas',       '0.00'],
      ['AOV',              'aov',                '$#,##0.00'],
      ['% NEW ORDERS',     'pct_new',            '0.0%']
    ],
    flagCol: 'AI',   // data_valid → grey
    flagStyle: 'grey',
    flagBlocks: ['BLENDED CAC', 'BLENDED ROAS', 'SITE ORDERS', 'NEW CUSTOMERS', 'AOV', '% NEW ORDERS']
  },
  'Site': {
    level: 'Site',
    rows: [
      ['All',          'All', ''],
      ['Web',          'All', ''],
      ['Subscription', 'All', ''],
      ['All',          'US',  ''],
      ['All',          'CA',  '']
    ],
    blocks: [
      ['ORDERS',         'site_orders',        '#,##0'],
      ['FIRST ORDERS',   'site_first_orders',  '#,##0'],
      ['NEW CUSTOMERS',  'site_new_customers', '#,##0'],
      ['GROSS SALES',    'site_gross_sales',   '$#,##0'],
      ['AOV',            'aov',                '$#,##0.00'],
      ['% NEW ORDERS',   'pct_new',            '0.0%']
    ],
    flagCol: 'AI',
    flagStyle: 'grey',
    flagBlocks: []
  }
};

var MONTHLY = {
  level: 'Business',
  rows: [
    ['Total Paid',        'All', ''],
    ['Sephora',           'All', ''],
    ['Sephora – Meta',    'All', ''],
    ['DTC',               'All', ''],
    ['DTC – Meta',        'All', ''],
    ['DTC – Google',      'All', ''],
    ['DTC – Shopify',     'All', '']
  ],
  blocks: [
    ['SPEND',             'spend',            '$#,##0'],
    ['SEPHORA PURCHASES', 'cs_purchases',     '#,##0'],
    ['SEPHORA ROAS',      'cs_roas',          '0.00'],
    ['PAID ROAS',         'paid_roas',        '0.00'],
    ['SITE ORDERS',       'site_orders',      '#,##0'],
    ['SITE GROSS SALES',  'site_gross_sales', '$#,##0'],
    ['BLENDED ROAS',      'blended_roas',     '0.00']
  ],
  flagCol: 'AI',
  flagStyle: 'grey',
  flagBlocks: ['SEPHORA PURCHASES', 'SEPHORA ROAS', 'SITE ORDERS', 'SITE GROSS SALES', 'BLENDED ROAS']
};

// ── palette ────────────────────────────────────────────────────────────────
var C = {
  header:  '#14201e',
  headerT: '#f6f5f0',
  block:   '#efede5',
  rule:    '#dfdcd1',
  amber:   '#f4e9cf',
  amberT:  '#8a6412',
  grey:    '#eeeeee',
  greyT:   '#999999',
  note:    '#66756f'
};

function buildReport() {
  var ss = SpreadsheetApp.getActive();
  ensureFeedTab_(ss);
  writeConfig_(ss);
  writeReadme_(ss);
  Object.keys(CONFIG).forEach(function (name) {
    buildGrid_(ss, name, CONFIG[name], 'week', WEEKS);
  });
  buildGrid_(ss, 'Monthly', MONTHLY, 'month', MONTHS);
  buildCampaigns_(ss);
  buildHealth_(ss);
  orderTabs_(ss);
  SpreadsheetApp.getActive().toast('Report rebuilt. Connect the Metabase extension to the `feed` tab.', 'Done', 8);
}

// ── helpers ────────────────────────────────────────────────────────────────

function sheet_(ss, name, wipe) {
  var sh = ss.getSheetByName(name);
  if (!sh) sh = ss.insertSheet(name);
  else if (wipe) { sh.clear(); sh.clearConditionalFormatRules(); }
  return sh;
}

function ensureFeedTab_(ss) {
  var sh = ss.getSheetByName(FEED);
  if (sh) return;                                  // never wipe a live feed
  sh = ss.insertSheet(FEED);
  sh.getRange('A1').setValue(
    'Connect the Metabase question "JM – Reporting Feed" to this tab. ' +
    'Header row must land in row 1. Do not edit this tab by hand.');
  sh.getRange('A1').setFontColor(C.note).setFontStyle('italic');
}

/** Formula that pulls one metric for one row/period, by header NAME. */
function cell_(level, rowLabelRef, marketRef, periodRef, metric) {
  return '=IFERROR(INDEX(' + FEED + '!$A:$AL,' +
         ' MATCH("' + level + '|"&' + rowLabelRef + '&"|"&' + marketRef + '&"|"&' + periodRef + ',' +
         ' ' + FEED + '!$H:$H, 0),' +
         ' MATCH("' + metric + '", ' + FEED + '!$1:$1, 0)), "")';
}

// ── grid tabs ──────────────────────────────────────────────────────────────

function buildGrid_(ss, name, cfg, grain, nPeriods) {
  var avgSpan = (grain === 'week') ? 4 : 3;   // periods in the rolling average
  var sh = sheet_(ss, name, true);
  var lastCol = 1 + nPeriods + 2;                  // label + periods + delta + avg

  sh.getRange(1, 1).setValue(name)
    .setFontSize(14).setFontWeight('bold').setFontColor(C.headerT);
  sh.getRange(1, 1, 1, lastCol).setBackground(C.header);

  sh.getRange('A2').setValue('Data through:');
  sh.getRange('B2').setFormula(
    '=IFERROR(TEXT(MAX(FILTER(' + FEED + '!$F:$F, ' + FEED + '!$A:$A="' + cfg.level + '")),"yyyy-mm-dd"),"— connect feed —")');
  sh.getRange('A3').setValue('Health:');
  sh.getRange('B3').setFormula('=COUNTIF(' + FEED + '!$AK:$AK,"FAIL")&" checks failing — see Health tab"');
  sh.getRange('A2:A3').setFontColor(C.note);
  sh.getRange('B3').setFontColor(C.amberT);

  var row = 5;
  cfg.blocks.forEach(function (blk) {
    var label = blk[0], metric = blk[1], fmt = blk[2];

    // block banner
    sh.getRange(row, 1, 1, lastCol).setBackground(C.block);
    sh.getRange(row, 1).setValue(label + '   ·   ' + metric)
      .setFontWeight('bold').setFontSize(9);
    row++;

    // period header — computed, so a new period appears on its own
    sh.getRange(row, 1).setValue(grain === 'week' ? 'Segment' : 'Row')
      .setFontWeight('bold');
    for (var p = 0; p < nPeriods; p++) {
      sh.getRange(row, 2 + p).setFormula(
        '=IFERROR(INDEX(SORT(UNIQUE(FILTER(' + FEED + '!$E:$E,' +
        ' ' + FEED + '!$A:$A="' + cfg.level + '", ' + FEED + '!$D:$D="' + grain + '",' +
        ' ' + FEED + '!$E:$E<>"")),1,FALSE), ' + (p + 1) + '), "")');
    }
    sh.getRange(row, 2 + nPeriods).setValue(grain === 'week' ? 'WoW %' : 'MoM %');
    sh.getRange(row, 3 + nPeriods).setValue(avgSpan + (grain === 'week' ? 'wk avg' : 'mo avg'));
    sh.getRange(row, 1, 1, lastCol)
      .setFontWeight('bold').setBackground(C.block).setBorder(null, null, true, null, null, null);
    var headerRow = row;
    row++;

    var firstDataRow = row;
    cfg.rows.forEach(function (r) {
      var rowLabel = r[0], market = r[1];
      sh.getRange(row, 1).setValue(rowLabel + (market !== 'All' ? '  (' + market + ')' : ''));
      for (var p = 0; p < nPeriods; p++) {
        var colL = colLetter_(2 + p);
        sh.getRange(row, 2 + p).setFormula(
          cell_(cfg.level, '"' + rowLabel + '"', '"' + market + '"',
                colL + '$' + headerRow, metric));
      }
      // Delta = latest vs prior. Rolling average spans the `avgSpan` periods
      // BEFORE the latest, so it is a comparison baseline rather than a window
      // that includes the number it is being compared against.
      var cLatest = colLetter_(2), cPrior = colLetter_(3);
      var cAvgEnd = colLetter_(2 + avgSpan);
      sh.getRange(row, 2 + nPeriods).setFormula(
        '=IFERROR(IF(' + cPrior + row + '=0,"",' + cLatest + row + '/' + cPrior + row + '-1),"")');
      sh.getRange(row, 3 + nPeriods).setFormula(
        '=IFERROR(AVERAGE(' + cPrior + row + ':' + cAvgEnd + row + '),"")');
      row++;
    });

    var lastDataRow = row - 1;
    sh.getRange(firstDataRow, 2, cfg.rows.length, nPeriods).setNumberFormat(fmt);
    sh.getRange(firstDataRow, 2 + nPeriods, cfg.rows.length, 1).setNumberFormat('+0.0%;-0.0%;0.0%');
    sh.getRange(firstDataRow, 3 + nPeriods, cfg.rows.length, 1).setNumberFormat(fmt);

    // Flag-driven conditional format. The formula is anchored at the range's
    // top-left, so $A<firstDataRow> offsets down per row and B$<headerRow>
    // offsets across per column — that is what makes one rule cover the block.
    // NOTE: the market is hardcoded '|All|' because every row on the two WoW
    // grids is market 'All'. A grid with per-row markets (Site) needs its own
    // rule per market, which is why Site's flagBlocks is empty.
    if (cfg.flagCol && cfg.flagBlocks.indexOf(label) >= 0) {
      var rng = sh.getRange(firstDataRow, 2, cfg.rows.length, nPeriods);
      var colL = colLetter_(2);
      var rule = SpreadsheetApp.newConditionalFormatRule()
        .whenFormulaSatisfied(
          '=IFERROR(INDEX(' + FEED + '!$' + cfg.flagCol + ':$' + cfg.flagCol + ',' +
          ' MATCH("' + cfg.level + '|"&$A' + firstDataRow + '&"|All|"&' + colL + '$' + headerRow + ',' +
          ' ' + FEED + '!$H:$H, 0))=FALSE, FALSE)')
        .setBackground(cfg.flagStyle === 'amber' ? C.amber : C.grey)
        .setFontColor(cfg.flagStyle === 'amber' ? C.amberT : C.greyT)
        .setRanges([rng]).build();
      var rules = sh.getConditionalFormatRules();
      rules.push(rule);
      sh.setConditionalFormatRules(rules);
    }
    row++;   // spacer
  });

  // targets, where set
  var noteRow = row + 1;
  var targets = cfg.rows.filter(function (r) { return r[2] !== ''; })
    .map(function (r) { return r[0] + ' ≥ ' + r[2]; });
  if (targets.length) {
    sh.getRange(noteRow, 1).setValue('Targets:  ' + targets.join('   ·   '))
      .setFontColor(C.note).setFontSize(9);
  }
  sh.getRange(noteRow + 1, 1).setValue(
    cfg.flagStyle === 'amber'
      ? 'Amber = real spend, conversions not reported (catalog segment missing). Act on it.'
      : 'Grey = the underlying data does not exist for that period. Ignore, do not backfill.')
    .setFontColor(C.note).setFontSize(9);

  sh.setColumnWidth(1, 210);
  for (var c = 2; c <= lastCol; c++) sh.setColumnWidth(c, 92);
  sh.setFrozenRows(1);
  sh.setFrozenColumns(1);
}

// ── QUERY tabs ─────────────────────────────────────────────────────────────

function buildCampaigns_(ss) {
  var sh = sheet_(ss, 'Campaigns', true);
  sh.getRange('A1').setValue('Campaigns')
    .setFontSize(14).setFontWeight('bold').setFontColor(C.headerT);
  sh.getRange('A1:K1').setBackground(C.header);
  sh.getRange('A2').setValue('Week:');
  sh.getRange('B2').setFormula(
    '=IFERROR(INDEX(SORT(UNIQUE(FILTER(' + FEED + '!$E:$E, ' + FEED + '!$A:$A="Campaign",' +
    ' ' + FEED + '!$E:$E<>"")),1,FALSE),1),"")');
  sh.getRange('A3').setValue('Read the read_metrics column: Sephora rows use cs_*, DTC rows use paid_*.')
    .setFontColor(C.note).setFontSize(9);
  sh.getRange('A5').setFormula(
    '=IFERROR(QUERY(' + FEED + '!$A:$AL,' +
    ' "select B, C, G, I, S, T, U, V, O, P, Q' +
    '   where A = \'Campaign\' and E = \'"&$B$2&"\'' +
    '   order by I desc' +
    '   label B \'Campaign\', C \'Market\', G \'Read\', I \'Spend\', S \'cs purch\', T \'cs rev\',' +
    ' U \'cs ROAS\', V \'cs CPA\', O \'paid purch\', P \'paid rev\', Q \'paid ROAS\'", 1),' +
    ' "No campaign rows — connect the feed.")');
  sh.setColumnWidth(1, 460);
  sh.setFrozenRows(5);
}

function buildHealth_(ss) {
  var sh = sheet_(ss, 'Health', true);
  sh.getRange('A1').setValue('Data Health')
    .setFontSize(14).setFontWeight('bold').setFontColor(C.headerT);
  sh.getRange('A1:C1').setBackground(C.header);
  sh.getRange('A2').setValue('Any FAIL here invalidates the numbers above it. Check before sending a report.')
    .setFontColor(C.note).setFontSize(9);
  sh.getRange('A4').setFormula(
    '=IFERROR(QUERY(' + FEED + '!$A:$AL,' +
    ' "select B, AK, AL where A = \'Health\' order by AK desc, B' +
    '   label B \'Check\', AK \'Status\', AL \'Detail\'", 1),' +
    ' "No health rows — connect the feed.")');
  var rules = [
    SpreadsheetApp.newConditionalFormatRule()
      .whenTextEqualTo('FAIL').setBackground('#f5e2dc').setFontColor('#96331f').setBold(true)
      .setRanges([sh.getRange('A4:C200')]).build(),
    SpreadsheetApp.newConditionalFormatRule()
      .whenTextEqualTo('OK').setFontColor('#33604a')
      .setRanges([sh.getRange('A4:C200')]).build()
  ];
  sh.setConditionalFormatRules(rules);
  sh.setColumnWidth(1, 300); sh.setColumnWidth(2, 80); sh.setColumnWidth(3, 380);
  sh.setFrozenRows(4);
}

// ── Config + README ────────────────────────────────────────────────────────

function writeConfig_(ss) {
  var sh = sheet_(ss, 'Config', true);
  var rows = [['tab', 'row_label', 'market', 'target']];
  Object.keys(CONFIG).forEach(function (t) {
    CONFIG[t].rows.forEach(function (r) { rows.push([t, r[0], r[1], r[2]]); });
  });
  MONTHLY.rows.forEach(function (r) { rows.push(['Monthly', r[0], r[1], r[2]]); });
  sh.getRange(1, 1, rows.length, 4).setValues(rows);
  sh.getRange(1, 1, 1, 4).setFontWeight('bold').setBackground(C.block);
  sh.getRange(rows.length + 2, 1).setValue(
    'Reference only. Row order and targets live in the CONFIG object at the top of ' +
    'the Apps Script — edit there and re-run buildReport. row_label must match the ' +
    'feed\'s row_label exactly.').setFontColor(C.note).setFontSize(9).setWrap(true);
  sh.setColumnWidth(1, 120); sh.setColumnWidth(2, 200);
}

function writeReadme_(ss) {
  var sh = sheet_(ss, 'README', true);
  var lines = [
    ['Josie Maran — Automated Reporting'],
    [''],
    ['SEPHORA AND DTC ARE MEASURED DIFFERENTLY. NEVER MIX THEM.'],
    ['Check column G (read_metrics) on the feed before reading any number. Sephora sells on'],
    ['sephora.com — the purchase fires on Sephora\'s pixel against Sephora\'s catalog segment, so it'],
    ['produces no Shopify order and no row in Meta\'s own purchases column. On the standard purchase'],
    ['column the Sephora account shows 18 purchases on $566,802 of 2026 spend; on catalog segment'],
    ['actions it has driven 6,797 purchases and $274,382 since March 2025.'],
    [''],
    ['COLLAB AND TRAFFIC MUST NEVER BE AVERAGED.'],
    ['Lifetime: US Traffic $1,460,035 → 0.04 ROAS ($937 CPA). US Collab $72,422 → 1.14 ROAS ($36).'],
    ['CA Collab $12,627 → 2.93 ROAS ($14). Collab spends 4.8% of Traffic\'s budget for 60% more'],
    ['purchases. In the week of 2026-08-31 it was 7.5% of Sephora spend and 145 of 148 purchases.'],
    [''],
    ['AMBER = REAL SPEND, UNREPORTED CONVERSIONS.'],
    ['The new "SB - US/CA - Sephora ... Traffic" campaigns replaced the legacy traffic campaigns'],
    ['around 2026-08-25 and emit no catalog-segment rows, while carrying ~92% of live Sephora spend.'],
    ['The legacy collab campaigns still report daily, so the pipeline is healthy — this is a'],
    ['campaign-setup gap. Kohl\'s traffic and the retired Engagement campaign have never emitted'],
    ['any ($354,678 lifetime).'],
    [''],
    ['62% OF US TRAFFIC CONVERSIONS ARE IN STORE, vs 7% of US Collab\'s. Traffic drives footfall,'],
    ['collab drives sephora.com. Judging traffic on online ROAS alone understates it — though 0.04'],
    ['is still 0.04.'],
    [''],
    ['GREY = DTC BLENDED METRICS START THE WEEK OF 2026-07-27. NOTHING EARLIER.'],
    ['Shopify order history begins there: 19 orders in the week of 07-20, then 2,737 in the week of'],
    ['07-27. August 2026 is the only complete month, so no blended MoM until October and no blended'],
    ['YoY this year. Paid-only DTC goes back further — Meta to 2023-07, Google to 2024-08. Sephora'],
    ['is the opposite: 18 months of catalog-segment history, so Sephora MoM and YoY both work now.'],
    [''],
    ['21% OF DTC ORDERS ARE SUBSCRIPTION RENEWALS (4,226 of 19,636, $232,177) and 78% of orders are'],
    ['repeat purchases. Site revenue moves largely independently of this week\'s spend. Against the'],
    ['plan\'s 70 New / 20 Engaged / 10 Existing target, judge paid on new-customer CAC and % new'],
    ['orders, not blended ROAS.'],
    [''],
    ['GOOGLE ADS RUNS ~8 DAYS BEHIND. Check the Health tab before comparing Google to another'],
    ['channel in the current week. Google\'s ~1,100% ROAS is correct — branded search is run to a'],
    ['deliberate 1,000% tROAS.'],
    [''],
    ['THREE CAMPAIGN NAMING CONVENTIONS ARE LIVE — tagged "plat:...", new "SB - ...", legacy'],
    ['"BD - ...". The dbt macros handle all three. A campaign matching none lands in Unclassified'],
    ['and shows up on the Health tab.'],
    [''],
    ['HOW THIS SHEET WORKS'],
    ['feed        one Metabase question, written by the extension. Never edit, sort or format it.'],
    ['grids       INDEX+MATCH into feed. Row matched on lookup_key (col H), metric matched by'],
    ['            header NAME — so adding a column to the question will not break them.'],
    ['Campaigns   one QUERY() formula. Health: one QUERY() formula.'],
    ['Config      reference. Real config is the CONFIG object in the Apps Script.'],
    ['To rebuild: Extensions → Apps Script → Run buildReport.']
  ];
  sh.getRange(1, 1, lines.length, 1).setValues(lines);
  sh.getRange(1, 1).setFontSize(14).setFontWeight('bold');
  [3, 10, 15, 22, 26, 32, 37, 41, 45].forEach(function (r) {
    sh.getRange(r, 1).setFontWeight('bold');
  });
  sh.setColumnWidth(1, 780);
  sh.getRange(1, 1, lines.length, 1).setVerticalAlignment('top');
}

function orderTabs_(ss) {
  ['README', 'Health', 'Sephora WoW', 'DTC WoW', 'Monthly', 'Site', 'Campaigns', 'Config', FEED]
    .forEach(function (name, i) {
      var sh = ss.getSheetByName(name);
      if (sh) { ss.setActiveSheet(sh); ss.moveActiveSheet(i + 1); }
    });
  var readme = ss.getSheetByName('README');
  if (readme) ss.setActiveSheet(readme);
}

function colLetter_(n) {
  var s = '';
  while (n > 0) { var m = (n - 1) % 26; s = String.fromCharCode(65 + m) + s; n = (n - m - 1) / 26; }
  return s;
}
