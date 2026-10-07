/**
 * Josie Maran — Budget Pacing & Daily Budgets
 * RUN: paste as a SECOND file next to build_gsheet.gs, Save, then Run ▸ buildReport
 * (or refreshAndRebuild). build_gsheet.gs calls into this file if it is present,
 * and skips it if it is not, so the existing report never depends on it.
 *
 * ── WHAT IT BUILDS ──────────────────────────────────────────────────────────
 * Two script-owned tabs, four stacked-column charts each (Sephora US, Sephora
 * CA, Sephora @ Kohls, DTC):
 *
 *   Budget Pacing  the month in progress. Days that are over show ACTUAL spend
 *                  in grey; the days still to come show the client's FORECAST
 *                  budget in colour. Above each chart, the headline the weekly
 *                  doc quotes: "spent X% of the monthly budget through Y% of
 *                  the month".
 *   DoD Budgets    the client's day-over-day budget for a whole month, all in
 *                  colour. Shows NEXT month once its budget exists (the
 *                  appendix of the meeting doc), else the current one.
 *
 * Data comes from the Metabase card in metabase/02_budget_pacing.sql, pulled
 * into the feed tab "budget pacing @ <PACING_CARD_ID>". Which campaigns exist,
 * their legend labels, stack order and colours all arrive in that feed from
 * seeds/budget_campaign_map.csv, so a new campaign needs a CSV line and no edit
 * here.
 *
 * ── WHY EACH CAMPAIGN IS TWO COLUMNS ────────────────────────────────────────
 * A Sheets chart cannot colour a bar by whether its day is in the past. The old
 * hand-built charts set grey on each day by hand (28 per-point overrides), which
 * is exactly what cannot be automated: the grey days shift every day. Instead
 * every campaign gets an "actual" column and a "forecast" column, each with a
 * fixed colour, and a day lands in one or the other. On any given day only one
 * of the pair holds a value, so the stack is unchanged. The actual columns are
 * hidden from the legend, so it reads like the doc's.
 *
 * ── WHAT IS DELIBERATELY NOT HERE ───────────────────────────────────────────
 *  - Chart titles carry no month. A title is a chart's identity: this file edits
 *    the existing chart in place (like build_gsheet.gs), which keeps its object
 *    ID, which is what keeps a chart linked into a Doc or Slides alive. A month
 *    in the title would mint a new chart, and break the link, every month.
 *  - The sale labels and numbered markers drawn on the doc's October charts
 *    (Prime Day, Free Shipping...). Those are hand-drawn overlays today.
 *  - A monthly budget total. It is the sum of the daily budgets by default. The
 *    sheet's own "Total Budget" row cannot be used: it leaves out NB PMax. To
 *    quote a different figure, type it in a block's "Budget override" cell; it
 *    survives rebuilds.
 *
 * ── LAYOUT IS FIXED ON PURPOSE ──────────────────────────────────────────────
 * Every block is PACING_BLOCK_ROWS tall and every override cell sits at a known
 * position, so a typed override can be read back before the tab is rebuilt.
 */

var PACING_CARD_ID = 0;   // Metabase question built from metabase/02_budget_pacing.sql.
                          // 0 = not wired up yet: these tabs are skipped, nothing else is affected.

function pacingFeedName_() { return 'budget pacing @ ' + PACING_CARD_ID; }

var PACING_UNITS = [
  { key: 'sephora_us',    title: 'Sephora US' },
  { key: 'sephora_ca',    title: 'Sephora CA' },
  { key: 'sephora_kohls', title: 'Sephora @ Kohls' },
  { key: 'dtc',           title: 'DTC' }
];

var PACING_TABS = {
  'Budget Pacing': { mode: 'pacing', chartSuffix: 'Budget Pacing',
                     blurb: 'Grey = actual spend from the warehouse. Colour = remaining forecast budget from the client sheet.' },
  'DoD Budgets':   { mode: 'budget', chartSuffix: 'Daily Budget',
                     blurb: "The client's planned spend per day. Shows next month once its budget exists, else this month." }
};

var PACING_FIRST_BLOCK_ROW = 5;    // rows 1-4 hold the tab title, month override and a note
var PACING_BLOCK_ROWS      = 38;   // title, 2 stats rows, headline, header, 31 days, 2 spare
var PACING_MAX_DAYS        = 31;
var PACING_CHART           = { width: 780, height: 340 };
var PACING_NOTE_COLOR      = '#66756f';
var PACING_REQUIRED_COLS   = ['date', 'month_start', 'business_unit', 'platform', 'campaign_key',
                              'legend_label', 'stack_order', 'forecast_color', 'actual_color',
                              'forecast_budget', 'actual_spend', 'is_actual'];

/* ════════════════════════════════════════════════════════════════════════════
   PURE LOGIC — no SpreadsheetApp in here, so it can be run and checked anywhere
   ════════════════════════════════════════════════════════════════════════════ */

/** yyyy-mm-dd from a Date (read back from a date-formatted cell) or a string. */
function pacingIso_(v, tz) {
  if (v instanceof Date) return Utilities.formatDate(v, tz, 'yyyy-MM-dd');
  return String(v).slice(0, 10);
}

function pacingNum_(v) {
  if (v === '' || v === null || v === undefined) return null;
  var n = Number(v);
  return isNaN(n) ? null : n;
}

/**
 * Feed values (header row + data) -> row objects. Columns are found by NAME,
 * never by position, so appending a column to the card cannot shift anything.
 */
function pacingParseFeed_(values, tz) {
  var header = values[0];
  var idx = {};
  PACING_REQUIRED_COLS.forEach(function (c) {
    idx[c] = header.indexOf(c);
    if (idx[c] < 0) {
      throw new Error('Budget pacing feed has no "' + c + '" column. Re-paste the card ' +
                      'from metabase/02_budget_pacing.sql and refresh.');
    }
  });
  var out = [];
  for (var r = 1; r < values.length; r++) {
    var row = values[r];
    if (row[idx.date] === '' || row[idx.business_unit] === '') continue;
    out.push({
      date:           pacingIso_(row[idx.date], tz),
      monthStart:     pacingIso_(row[idx.month_start], tz),
      unit:           String(row[idx.business_unit]),
      platform:       String(row[idx.platform]),
      key:            String(row[idx.campaign_key]),
      label:          String(row[idx.legend_label] || ''),
      order:          pacingNum_(row[idx.stack_order]),
      forecastColor:  String(row[idx.forecast_color] || ''),
      actualColor:    String(row[idx.actual_color] || ''),
      forecast:       pacingNum_(row[idx.forecast_budget]),
      actual:         pacingNum_(row[idx.actual_spend]),
      isActual:       Number(row[idx.is_actual]) === 1
    });
  }
  return out;
}

function pacingMonthOf_(iso) { return iso.slice(0, 8) + '01'; }

function pacingAddMonth_(monthIso, n) {
  var y = Number(monthIso.slice(0, 4)), m = Number(monthIso.slice(5, 7)) - 1 + n;
  y += Math.floor(m / 12); m = ((m % 12) + 12) % 12;
  return y + '-' + (m < 9 ? '0' : '') + (m + 1) + '-01';
}

function pacingDaysInMonth_(monthIso) {
  return new Date(Date.UTC(Number(monthIso.slice(0, 4)), Number(monthIso.slice(5, 7)), 0)).getUTCDate();
}

function pacingDays_(monthIso) {
  var out = [], n = pacingDaysInMonth_(monthIso), p = monthIso.slice(0, 8);
  for (var d = 1; d <= n; d++) out.push(p + (d < 10 ? '0' : '') + d);
  return out;
}

/** '2026-10-07' -> '10/7', the label the doc's charts use. */
function pacingLabel_(iso) { return Number(iso.slice(5, 7)) + '/' + Number(iso.slice(8, 10)); }

var PACING_MONTH_NAMES = ['January', 'February', 'March', 'April', 'May', 'June', 'July',
                          'August', 'September', 'October', 'November', 'December'];
function pacingMonthName_(monthIso) {
  return PACING_MONTH_NAMES[Number(monthIso.slice(5, 7)) - 1] + ' ' + monthIso.slice(0, 4);
}

function pacingDaysBetween_(aIso, bIso) {
  var a = Date.UTC(Number(aIso.slice(0, 4)), Number(aIso.slice(5, 7)) - 1, Number(aIso.slice(8, 10)));
  var b = Date.UTC(Number(bIso.slice(0, 4)), Number(bIso.slice(5, 7)) - 1, Number(bIso.slice(8, 10)));
  return Math.round((b - a) / 86400000);
}

/**
 * Which month each tab shows.
 *   pacing  the month of the latest day that has ACTUAL data, so the tab follows
 *           the data: on the 1st it still shows the month that just closed, and
 *           turns over once the new month has a day of actuals.
 *   budget  the month after that, if the client has budgeted it; else the same.
 * A valid override (a yyyy-mm date typed into B2) wins for its own tab.
 */
function pacingPickMonths_(rows, overrideIso) {
  var months = {}, maxActual = '';
  rows.forEach(function (r) {
    months[r.monthStart] = true;
    if (r.isActual && r.date > maxActual) maxActual = r.date;
  });
  var available = Object.keys(months).sort();
  var pacing = maxActual ? pacingMonthOf_(maxActual) : (available[0] || '');
  var next = pacing ? pacingAddMonth_(pacing, 1) : '';
  var nextBudgeted = rows.some(function (r) { return r.monthStart === next && r.forecast !== null; });
  var out = { pacing: pacing, budget: nextBudgeted ? next : pacing, available: available,
              maxActual: maxActual, overrideIgnored: false };
  if (overrideIso) {
    var o = pacingMonthOf_(overrideIso);
    if (months[o]) { out.pacing = o; out.budget = o; }
    else out.overrideIgnored = true;
  }
  return out;
}

/**
 * One business unit, one month -> everything the sheet and the chart need.
 *   columns  the chart series, in stack order. pacing mode gives every campaign
 *            an actual column then a forecast column; budget mode just forecast.
 *   matrix   one row per day of the month: [label, ...one value per column]
 *   stats    spent / planned / last actual day / days elapsed
 * A series that is zero all month is dropped, so a line the client has not
 * started budgeting yet cannot clutter the legend.
 */
function pacingUnitModel_(rows, unitKey, monthIso, mode) {
  var mine = rows.filter(function (r) { return r.unit === unitKey && r.monthStart === monthIso; });
  var days = pacingDays_(monthIso);
  var byId = {}, cell = {};
  var stats = { spent: 0, planned: 0, lastActual: '', elapsedDays: 0, daysInMonth: days.length };

  mine.forEach(function (r) {
    var id = r.platform + '|' + r.key;
    var s = byId[id] || (byId[id] = {
      id: id, label: r.label || r.key, order: r.order === null ? 999 : r.order,
      forecastColor: r.forecastColor || '#999999', actualColor: r.actualColor || '#666666', mass: 0 });
    s.mass += Math.abs(r.forecast || 0) + Math.abs(r.actual || 0);
    cell[r.date + '|' + id] = r;
    if (r.forecast !== null) stats.planned += r.forecast;
    if (r.isActual && r.actual !== null) {
      stats.spent += r.actual;
      if (r.date > stats.lastActual) stats.lastActual = r.date;
    }
  });
  if (stats.lastActual) stats.elapsedDays = pacingDaysBetween_(monthIso, stats.lastActual) + 1;

  var series = Object.keys(byId).map(function (k) { return byId[k]; })
    .filter(function (s) { return s.mass > 0; })
    .sort(function (a, b) { return a.order - b.order || (a.id < b.id ? -1 : 1); });

  var columns = [];
  series.forEach(function (s) {
    if (mode === 'pacing') {
      columns.push({ id: s.id, kind: 'actual',   header: s.label + ' (actual)', color: s.actualColor });
    }
    columns.push({ id: s.id, kind: 'forecast', header: s.label, color: s.forecastColor });
  });

  var matrix = days.map(function (d) {
    var line = [pacingLabel_(d)];
    columns.forEach(function (c) {
      var r = cell[d + '|' + c.id], v = '';
      if (r) {
        if (c.kind === 'actual') {
          v = (r.isActual && r.actual !== null) ? r.actual : '';
        } else if (mode === 'pacing') {
          v = (!r.isActual && r.forecast !== null) ? r.forecast : '';
        } else {
          v = r.forecast !== null ? r.forecast : '';
        }
      }
      line.push(v);
    });
    return line;
  });

  return { unitKey: unitKey, monthIso: monthIso, empty: columns.length === 0,
           columns: columns, matrix: matrix, days: days, stats: stats };
}

/** The chart's options, as plain data. Colours come from the feed, not from here. */
function pacingChartOptions_(model, title, mode) {
  var series = {};
  model.columns.forEach(function (c, i) {
    series[i] = { color: c.color, visibleInLegend: !(mode === 'pacing' && c.kind === 'actual') };
  });
  return { title: title, series: series, legend: { position: 'top' },
           vAxis: { format: '$#,##0' }, width: PACING_CHART.width, height: PACING_CHART.height };
}

/* ════════════════════════════════════════════════════════════════════════════
   SHEET WRITING — thin wrappers around the pure functions above
   ════════════════════════════════════════════════════════════════════════════ */

/**
 * Called from buildReport(). Never lets a problem here stop the rest of the
 * report: a failure is written into the tab where someone will see it.
 */
function buildPacingTabs_(ss) {
  if (!PACING_CARD_ID) {
    Logger.log('Budget pacing tabs skipped: PACING_CARD_ID is not set.');
    return;
  }
  try {
    var feed = ss.getSheetByName(pacingFeedName_());
    if (!feed || feed.getLastRow() < 2) {
      throw new Error('Feed tab "' + pacingFeedName_() + '" is missing or empty. Point the ' +
                      'Metabase extension at question ' + PACING_CARD_ID + ' or run refreshAndRebuild.');
    }
    var tz = ss.getSpreadsheetTimeZone();
    var rows = pacingParseFeed_(feed.getDataRange().getValues(), tz);
    Object.keys(PACING_TABS).forEach(function (name) {
      buildPacingTab_(ss, name, PACING_TABS[name], rows, tz);
    });
  } catch (e) {
    Logger.log('Budget pacing tabs failed: ' + e.message);
    Object.keys(PACING_TABS).forEach(function (name) {
      var sh = pacingSheet_(ss, name);
      sh.getRange(3, 1).setValue('⚠ Build failed: ' + e.message);
    });
    ss.toast('Budget pacing tabs failed: ' + e.message, 'Check "Budget Pacing"', 15);
  }
}

/** The tab, created on first use. It is wiped by buildPacingTab_, which leaves charts alone. */
function pacingSheet_(ss, name) {
  return ss.getSheetByName(name) || ss.insertSheet(name);
}

/** A user-typed month (B2) and per-block budget overrides, read before the tab is wiped. */
function pacingReadKeep_(sh, tz) {
  var keep = { month: '', override: {} };
  if (!sh) return keep;
  var m = sh.getRange(2, 2).getValue();
  if (m !== '' && m !== null) {
    var iso = pacingIso_(m, tz);
    if (/^\d{4}-\d{2}/.test(iso)) keep.month = iso.slice(0, 7) + '-01';
  }
  PACING_UNITS.forEach(function (u, i) {
    var v = sh.getRange(PACING_FIRST_BLOCK_ROW + i * PACING_BLOCK_ROWS + 2, 3).getValue();
    if (typeof v === 'number' && v > 0) keep.override[u.key] = v;
  });
  return keep;
}

function buildPacingTab_(ss, name, cfg, rows, tz) {
  var sh = pacingSheet_(ss, name);
  var keep = pacingReadKeep_(sh, tz);
  sh.clear();
  sh.clearConditionalFormatRules();

  var months = pacingPickMonths_(rows, keep.month);
  var month = cfg.mode === 'pacing' ? months.pacing : months.budget;

  sh.getRange(1, 1).setValue(name).setFontWeight('bold').setFontSize(14);
  sh.getRange(2, 1).setValue('Month override (optional, e.g. 2026-10-01)');
  sh.getRange(2, 2).setNumberFormat('@').setValue(keep.month);
  sh.getRange(2, 3).setValue('Showing');
  sh.getRange(2, 4).setValue(pacingMonthName_(month)).setFontWeight('bold');
  // A stale feed must not look current: say how far the actuals actually go.
  sh.getRange(2, 5).setValue('Actuals through');
  sh.getRange(2, 6).setNumberFormat('@').setValue(months.maxActual || 'none yet').setFontWeight('bold');
  sh.getRange(3, 1).setValue(cfg.blurb +
    (months.overrideIgnored ? '  (Month override ignored: that month is not in the feed.)' : ''));
  sh.getRange(3, 1).setFontColor(PACING_NOTE_COLOR);

  var wanted = {};
  PACING_UNITS.forEach(function (u, i) {
    var top = PACING_FIRST_BLOCK_ROW + i * PACING_BLOCK_ROWS;
    var model = pacingUnitModel_(rows, u.key, month, cfg.mode);
    writePacingBlock_(sh, top, u, model, cfg, keep.override[u.key]);
    if (!model.empty) {
      var title = u.title + ' — ' + cfg.chartSuffix;
      wanted[title] = true;
      upsertPacingChart_(sh, top, model, title, cfg.mode);
    }
  });
  prunePacingCharts_(sh, cfg, wanted);
}

function writePacingBlock_(sh, top, unit, model, cfg, overrideValue) {
  sh.getRange(top, 1).setValue(unit.title).setFontWeight('bold').setFontSize(12);
  if (model.empty) {
    sh.getRange(top + 1, 1).setValue('No budget rows for ' + pacingMonthName_(model.monthIso) + '.')
      .setFontColor(PACING_NOTE_COLOR);
    return;
  }
  var s = model.stats, r = top + 2;   // r = the stats values row

  if (cfg.mode === 'pacing') {
    sh.getRange(top + 1, 1, 1, 7).setValues([['Spent to date', 'Planned (sum of daily budgets)',
      'Budget override (type to use)', 'Budget used', '% of budget spent', 'Days elapsed',
      '% of month elapsed']]).setFontColor(PACING_NOTE_COLOR);
    sh.getRange(r, 1).setValue(s.spent).setNumberFormat('$#,##0');
    sh.getRange(r, 2).setValue(s.planned).setNumberFormat('$#,##0');
    sh.getRange(r, 3).setNumberFormat('$#,##0');
    if (overrideValue) sh.getRange(r, 3).setValue(overrideValue);
    sh.getRange(r, 4).setFormula('=IF(ISNUMBER(C' + r + '),C' + r + ',B' + r + ')').setNumberFormat('$#,##0');
    sh.getRange(r, 5).setFormula('=IFERROR(A' + r + '/D' + r + ',"")').setNumberFormat('0%');
    sh.getRange(r, 6).setValue(s.elapsedDays);
    sh.getRange(r, 7).setFormula('=F' + r + '/' + s.daysInMonth).setNumberFormat('0%');
    sh.getRange(top + 3, 1).setFormula(
      '="We have spent "&TEXT(E' + r + ',"0%")&" of our monthly budget ($"&TEXT(D' + r +
      ',"#,##0")&") through the first "&TEXT(G' + r + ',"0%")&" of the month."').setFontWeight('bold');
  } else {
    sh.getRange(top + 1, 1, 1, 2).setValues([['Planned (sum of daily budgets)', 'Daily average']])
      .setFontColor(PACING_NOTE_COLOR);
    sh.getRange(r, 1).setValue(s.planned).setNumberFormat('$#,##0');
    sh.getRange(r, 2).setValue(s.planned / s.daysInMonth).setNumberFormat('$#,##0');
    sh.getRange(top + 3, 1).setFormula(
      '=TEXT(A' + r + ',"$#,##0")&" planned for the month, averaging "&TEXT(B' + r +
      ',"$#,##0")&" a day."').setFontWeight('bold');
  }

  var headerRow = top + 4, nCols = 1 + model.columns.length;
  var header = ['Date'].concat(model.columns.map(function (c) { return c.header; }));
  sh.getRange(headerRow, 1, 1, nCols).setValues([header]).setFontWeight('bold');
  // Dates as TEXT labels ('10/7'): a real date column makes the chart draw a
  // continuous time axis with thin bars, where the doc's charts are discrete.
  sh.getRange(headerRow + 1, 1, model.matrix.length, 1).setNumberFormat('@');
  sh.getRange(headerRow + 1, 1, model.matrix.length, nCols).setValues(model.matrix);
  sh.getRange(headerRow + 1, 2, model.matrix.length, nCols - 1).setNumberFormat('$#,##0.00');
}

function upsertPacingChart_(sh, top, model, title, mode) {
  var headerRow = top + 4, nCols = 1 + model.columns.length;
  var range = sh.getRange(headerRow, 1, 1 + model.matrix.length, nCols);
  var opts = pacingChartOptions_(model, title, mode);

  var existing = sh.getCharts(), match = null;
  for (var i = 0; i < existing.length; i++) {
    if (pacingChartTitle_(existing[i]) === title) { match = existing[i]; break; }
  }
  // setStacked() exists only on the column builder; modify() returns a generic
  // builder that may not have it. The isStacked option works on both, so it is
  // what keeps an EXISTING chart stacked; setStacked() just makes a new one right.
  var b = match ? match.modify() : sh.newChart().asColumnChart().setStacked();
  if (match) b.clearRanges();
  b.addRange(range)
    .setNumHeaders(1)
    .setOption('isStacked', true)
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

function pacingChartTitle_(chart) {
  try { return chart.getOptions().get('title') || ''; } catch (e) { return ''; }
}

/** Remove only charts this file would have made (right suffix) that this run no longer produces. */
function prunePacingCharts_(sh, cfg, wanted) {
  sh.getCharts().forEach(function (ch) {
    var t = pacingChartTitle_(ch);
    if (t && t.slice(-cfg.chartSuffix.length) === cfg.chartSuffix && !wanted[t]) sh.removeChart(ch);
  });
}

/**
 * Pull a Metabase card into a feed tab. Same shape as refreshFeed_ in
 * build_gsheet.gs, and the same two lessons: use the CSV endpoint (it keeps the
 * column order) and set number formats BEFORE writing values, because Sheets
 * coerces on write: the date columns must land as real dates. Shared by every
 * card this project pulls (pacing, sales), so they cannot drift apart.
 */
function refreshCardFeed_(cardId, tabName, dateCols) {
  var cfg = mbConfig_();
  var res = UrlFetchApp.fetch(
    cfg.url + '/api/card/' + cardId + '/query/csv',
    { method: 'post', headers: { 'x-api-key': cfg.key }, muteHttpExceptions: true });
  var code = res.getResponseCode();
  if (code !== 200) {
    throw new Error('Metabase returned ' + code + ' for card ' + cardId + '. ' +
                    (code === 401 || code === 403
                       ? 'Check the API key and that its group can read the database.'
                       : res.getContentText().slice(0, 300)));
  }
  var rows = Utilities.parseCsv(res.getContentText());
  if (!rows.length || rows[0].length < 2) throw new Error('Card ' + cardId + ' returned no columns.');

  var ss = SpreadsheetApp.getActive();
  var sh = ss.getSheetByName(tabName) || ss.insertSheet(tabName);
  sh.clear();
  var n = rows.length;
  dateCols.forEach(function (c) {
    var col = rows[0].indexOf(c);
    if (col >= 0) sh.getRange(1, col + 1, n, 1).setNumberFormat('yyyy-mm-dd');
  });
  sh.getRange(1, 1, n, rows[0].length).setValues(rows);
  sh.setFrozenRows(1);
  return n - 1;
}

function refreshPacingFeed_() {
  if (!PACING_CARD_ID) return 0;
  return refreshCardFeed_(PACING_CARD_ID, pacingFeedName_(), ['date', 'month_start']);
}
