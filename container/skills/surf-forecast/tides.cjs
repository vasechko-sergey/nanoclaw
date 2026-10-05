#!/usr/bin/env node
/**
 * Tides for the surf-forecast render, from surf-forecast.com's tide page.
 *
 * The page carries its whole tide table as JSON (`window.FCGON = {...}`):
 * heights every 10 minutes in metres above chart datum — the scale the breaks'
 * `ideal_tide_m` is written in — plus each day's high/low events. Open-Meteo's
 * `sea_level_height_msl` is relative to mean sea level (it goes negative), so
 * rating spots against it picks the wrong window (2026-10-04).
 *
 * Usage: node tides.cjs <tide_url> <YYYY-MM-DD>
 *
 * Prints JSON for that local date:
 *   hourly       [{ h, v }] on the hour, 0..23 — read the window's tide here
 *   extremes     [{ type: "high"|"low", t: "HH:MM", h, v }]
 *   tidePoints   render.cjs field, hourly plus one point either side of the day
 *   tideMarkers  render.cjs field, one per high/low
 *   tideRange    render.cjs field, room for the marker labels
 * Exits 1 with the reason on stderr when the page or the date isn't there.
 */
'use strict';

const MARKER = 'window.FCGON = ';

function parseFcgon(html) {
  const start = html.indexOf(MARKER);
  if (start < 0) throw new Error('no window.FCGON on the page — layout changed or the request was blocked');
  const end = html.indexOf('\n', start);
  const raw = html
    .slice(start + MARKER.length, end < 0 ? undefined : end)
    .trim()
    .replace(/;$/, '');
  const fcgon = JSON.parse(raw);
  if (!Array.isArray(fcgon.tideDays)) throw new Error('FCGON has no tideDays');
  return fcgon;
}

/** Local wall-clock hours (e.g. 5.18 for 05:11) and "HH:MM" of a tide point. */
function localTime(point, hrdiff) {
  const d = new Date((point.timestamp + hrdiff * 3600) * 1000);
  const hh = d.getUTCHours();
  const mm = d.getUTCMinutes();
  return {
    h: Math.round((hh + mm / 60) * 100) / 100,
    t: `${String(hh).padStart(2, '0')}:${String(mm).padStart(2, '0')}`,
  };
}

function round2(x) {
  return Math.round(x * 100) / 100;
}

function onTheHour(day, hrdiff) {
  return day.tides
    .filter((p) => p.type === null)
    .map((p) => ({ ...localTime(p, hrdiff), v: p.height }))
    .filter((p) => p.t.endsWith(':00'));
}

function tidesForDate(fcgon, date) {
  const hrdiff = Number(fcgon.hrdiff) || 0;
  const idx = fcgon.tideDays.findIndex((d) => d.date === date);
  if (idx < 0) {
    const have = fcgon.tideDays.map((d) => d.date);
    throw new Error(`no tides for ${date} on the page (it has ${have[0]} … ${have[have.length - 1]})`);
  }
  const day = fcgon.tideDays[idx];
  const hourly = onTheHour(day, hrdiff).map(({ h, v }) => ({ h, v }));
  if (hourly.length < 20) throw new Error(`only ${hourly.length} hourly tide points for ${date}`);

  const extremes = day.tides
    .filter((p) => p.type === 'high' || p.type === 'low')
    .map((p) => ({ type: p.type, ...localTime(p, hrdiff), v: p.height }));

  // One point either side of the day keeps the spline smooth at the edges.
  const prev = fcgon.tideDays[idx - 1]
    ? onTheHour(fcgon.tideDays[idx - 1], hrdiff).find((p) => p.t === '23:00')
    : undefined;
  const next = fcgon.tideDays[idx + 1]
    ? onTheHour(fcgon.tideDays[idx + 1], hrdiff).find((p) => p.t === '00:00')
    : undefined;
  const tidePoints = [...(prev ? [{ h: -1, v: prev.v }] : []), ...hourly, ...(next ? [{ h: 24, v: next.v }] : [])];

  // Labels go inside the curve — under a high, over a low. Outside, a low's
  // label falls off the bottom of the tide card and a high's runs into the
  // "лучшее окно" caption at the top.
  const tideMarkers = extremes.map((e) => ({
    h: e.h,
    v: e.v,
    t: e.t,
    val: `${e.v.toFixed(1)} м`,
    above: e.type === 'low',
  }));

  // Headroom over the highest point keeps its marker clear of that caption.
  const vs = tidePoints.map((p) => p.v);
  const lo = Math.min(...vs);
  const hi = Math.max(...vs);
  const tideRange = [round2(lo - (hi - lo) * 0.12), round2(hi + (hi - lo) * 0.25)];

  return { date, source: 'surf-forecast.com', hourly, extremes, tidePoints, tideMarkers, tideRange };
}

async function main() {
  const [url, date] = process.argv.slice(2);
  if (!url || !/^\d{4}-\d{2}-\d{2}$/.test(date || '')) {
    console.error('Usage: node tides.cjs <tide_url> <YYYY-MM-DD>');
    process.exit(1);
  }
  const res = await fetch(url, {
    headers: { 'User-Agent': 'Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/537.36 (KHTML, like Gecko)' },
    signal: AbortSignal.timeout(20_000),
  });
  if (!res.ok) throw new Error(`${url} → HTTP ${res.status}`);
  console.log(JSON.stringify(tidesForDate(parseFcgon(await res.text()), date)));
}

if (require.main === module) {
  main().catch((err) => {
    console.error(`tides.cjs: ${err.message}`);
    process.exit(1);
  });
}

module.exports = { parseFcgon, tidesForDate };
