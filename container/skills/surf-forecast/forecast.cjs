#!/usr/bin/env node
/**
 * The surf-forecast skill end to end, without a model: Open-Meteo wave and
 * wind, surf-forecast.com tides (tides.cjs), the rules below, render.cjs →
 * one JPEG. A model following SKILL.md by hand cut corners on every step
 * (2026-10-04: tides from the wrong scale, five spots on a three-card canvas).
 *
 * Usage: node forecast.cjs [--lat <deg> --lon <deg>] [--area <key>] [--date YYYY-MM-DD] [--out <dir>]
 *   --lat/--lon  where the person is; default $DEVICE_LAT/$DEVICE_LON (the
 *                runner passes the phone's position from the command message)
 *   --area       a key of spots.json areas, for "the forecast for Ericeira";
 *                with no position either, the area for $OWNER_TZ — the area
 *                centre then stands in for the person
 *   --date       default: today in the area's time zone before 08:00, tomorrow after
 *   --out        default: /workspace/agent/scratch
 *   --spots      the catalogue file; default: the person's (see below)
 *   --check      only validate the catalogue
 *
 * Prints JSON { photo, params, summary } and also keeps it as surf_last.json
 * next to the photo, for questions about the picture later. Exits 1 with the
 * reason on stderr when anything is missing.
 *
 * The spot catalogue is the person's: /workspace/agent/memories/self/surf-spots.json,
 * seeded from this skill's spots.json. The agent changes it only through
 * spots.cjs; its contract lives in catalog.cjs. A file that breaks the
 * contract fails the run with what is wrong; `--check` validates it alone.
 *
 * Which spots: every catalogue spot within reach_km of the person (≈20 min
 * of driving), of the nearest one's area. They are all rated; the picture
 * shows the three best — green, then yellow, the nearer first within a
 * colour. Red is never drawn (the owner's call); it stays in the summary.
 * A time zone holds many spot sets (Canggu and Berawa are one zone, two
 * sets), so the position decides, not the zone.
 *
 * Rules — the skill's §2 made exact, tide bands from the owner's spot notes:
 * - Surfable window: the area's window_hours, starting no earlier than sunrise.
 * - Wind is offshore when it blows from within 67.5° of shore_facing_deg + 180.
 * - Tide, per spot: inside [lo, hi] (hi may be null) for at least 30 minutes
 *   of the window → ok; else below lo but not below lo − 0.5 → yellow, lower
 *   → red; above hi, or in range only briefly → yellow. A beach break is
 *   never worse than yellow on tide.
 * - Period at mid-window: ≥ min_period_s ok; up to 1 s short → yellow; more → red.
 * - Wave height at mid-window: ≥ min_swell_m ok; ≥ 0.5 m → yellow; less → red;
 *   above an optional max_swell_m → yellow.
 * - A spot is red on any red or on two yellows, yellow on one, green otherwise.
 * - Best window: the longest stretch with offshore wind and the tide in range
 *   for at least one shown spot that isn't red.
 */
'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { execFileSync } = require('node:child_process');

const { loadTides } = require('./tides.cjs');
const { PERSON_SPOTS, loadCatalog } = require('./catalog.cjs');

const MONTHS = [
  'ЯНВАРЯ',
  'ФЕВРАЛЯ',
  'МАРТА',
  'АПРЕЛЯ',
  'МАЯ',
  'ИЮНЯ',
  'ИЮЛЯ',
  'АВГУСТА',
  'СЕНТЯБРЯ',
  'ОКТЯБРЯ',
  'НОЯБРЯ',
  'ДЕКАБРЯ',
];
const COMPASS = ['N', 'NE', 'E', 'SE', 'S', 'SW', 'W', 'NW'];
const STEP_H = 10 / 60; // the window is scanned in 10-minute steps
const MIN_TIDE_SPAN_H = 0.5; // in range for less than this is no session
const RANK = { green: 0, yellow: 1, red: 2 };

const round1 = (x) => Math.round(x * 10) / 10;
const round2 = (x) => Math.round(x * 100) / 100;

/** "HH:MM" of a decimal hour. */
function hhmm(h) {
  const total = Math.round(h * 60);
  return `${String(Math.floor(total / 60)).padStart(2, '0')}:${String(total % 60).padStart(2, '0')}`;
}

/** 8-point compass label, as in SKILL.md §2 (0–22 N, 23–67 NE, …). */
function compass(deg) {
  return COMPASS[Math.round((((deg % 360) + 360) % 360) / 45) % 8];
}

function isOffshore(windFromDeg, shoreFacingDeg) {
  const offshoreFrom = (shoreFacingDeg + 180) % 360;
  const diff = Math.abs(((windFromDeg - offshoreFrom + 540) % 360) - 180);
  return diff <= 67.5;
}

/** Great-circle distance in km. */
function haversineKm(a, b) {
  const rad = (d) => (d * Math.PI) / 180;
  const h =
    Math.sin(rad(b.lat - a.lat) / 2) ** 2 +
    Math.cos(rad(a.lat)) * Math.cos(rad(b.lat)) * Math.sin(rad(b.lon - a.lon) / 2) ** 2;
  return 2 * 6371 * Math.asin(Math.sqrt(h));
}

/**
 * The spots within reach of `at` ({lat, lon}), nearest first, all of one area
 * (the nearest spot's), each with its distance_km.
 */
function pickSpots(catalog, at) {
  const all = catalog.spots
    .map((s) => ({ ...s, distance_km: Math.round(haversineKm(at, s) * 100) / 100 }))
    .sort((a, b) => a.distance_km - b.distance_km);
  const reach = all.filter((s) => s.distance_km <= catalog.reach_km);
  if (reach.length === 0) {
    const n = all[0];
    throw new Error(
      `no known spot within ${catalog.reach_km} km` +
        (n ? ` — the nearest is ${n.name}, ${round1(n.distance_km)} km` : ''),
    );
  }
  const areaKey = reach[0].area;
  const area = catalog.areas[areaKey];
  if (!area) throw new Error(`spot ${reach[0].name} names unknown area ${areaKey}`);
  return { areaKey, area, spots: reach.filter((s) => s.area === areaKey) };
}

/** Linear interpolation over [{h, v}] sorted by h. */
function interpolate(points, h) {
  if (h <= points[0].h) return points[0].v;
  for (let i = 1; i < points.length; i++) {
    if (h <= points[i].h) {
      const a = points[i - 1];
      const b = points[i];
      return a.v + ((b.v - a.v) * (h - a.h)) / (b.h - a.h);
    }
  }
  return points[points.length - 1].v;
}

/** Open-Meteo hourly arrays → [{h, v}] for one field. */
function hourlySeries(api, field) {
  const times = api && api.hourly && api.hourly.time;
  const values = api && api.hourly && api.hourly[field];
  if (!Array.isArray(times) || !Array.isArray(values) || times.length < 24) {
    throw new Error(`Open-Meteo answer has no hourly ${field}${api && api.reason ? `: ${api.reason}` : ''}`);
  }
  return times.map((t, i) => ({ h: Number(t.slice(11, 13)), v: values[i] })).filter((p) => p.v != null);
}

/** Grid points of [start, end] in 10-minute steps. */
function grid(start, end) {
  const out = [];
  for (let k = 0; start + k * STEP_H <= end + 1e-9; k++) out.push(round2(start + k * STEP_H));
  return out;
}

/** Longest run of consecutive grid points where `ok` holds → { a, b } or null. */
function longestRun(points, ok) {
  let best = null;
  let runStart = null;
  for (const h of points) {
    if (ok(h)) {
      if (runStart === null) runStart = h;
      const run = { a: runStart, b: h };
      if (!best || run.b - run.a > best.b - best.a) best = run;
    } else {
      runStart = null;
    }
  }
  return best;
}

function spanText(span, start, end) {
  const fromStart = span.a <= start + 1e-9;
  const toEnd = span.b >= end - 1e-9;
  if (fromStart && toEnd) return 'всё утро';
  if (fromStart) return `до ${hhmm(span.b)}`;
  if (toEnd) return `с ${hhmm(span.a)}`;
  return `${hhmm(span.a)}–${hhmm(span.b)}`;
}

function rateSpot(spot, ctx) {
  const { tideAt, window, hm, period } = ctx;
  const [lo, hi] = spot.ideal_tide_m;
  const tideOk = (h) => tideAt(h) >= lo && (hi == null || tideAt(h) <= hi);
  const run = longestRun(window.grid, tideOk);
  const span = run && run.b - run.a >= MIN_TIDE_SPAN_H - 1e-9 ? run : null;

  const verdicts = []; // { level: 'yellow'|'red', why }
  if (!span) {
    const tides = window.grid.map(tideAt);
    const highest = Math.max(...tides);
    const lowest = Math.min(...tides);
    if (highest < lo) {
      let level = highest >= lo - 0.5 ? 'yellow' : 'red';
      if (spot.type === 'beach') level = 'yellow';
      verdicts.push({ level, why: `прилив до ${round1(highest)} м — мелко` });
    } else if (hi != null && lowest > hi) {
      verdicts.push({ level: 'yellow', why: `прилив от ${round1(lowest)} м — высоко` });
    } else {
      const band = hi == null ? `от ${lo}` : `${lo}–${hi}`;
      verdicts.push({ level: 'yellow', why: `прилив ${round1(lowest)}–${round1(highest)} м, нужно ${band}` });
    }
  }
  if (period < spot.min_period_s) {
    verdicts.push({
      level: period >= spot.min_period_s - 1 ? 'yellow' : 'red',
      why: `период ${Math.round(period)} с, нужно от ${spot.min_period_s}`,
    });
  }
  if (hm < spot.min_swell_m) {
    verdicts.push({ level: hm >= 0.5 ? 'yellow' : 'red', why: `волна ${round1(hm)} м, нужно от ${spot.min_swell_m}` });
  } else if (spot.max_swell_m != null && hm > spot.max_swell_m) {
    verdicts.push({ level: 'yellow', why: `волна ${round1(hm)} м, больше ${spot.max_swell_m}` });
  }

  const reds = verdicts.filter((v) => v.level === 'red').length;
  const yellows = verdicts.length - reds;
  const rating = reds > 0 || yellows > 1 ? 'red' : yellows === 1 ? 'yellow' : 'green';

  const tideNote = span ? `прилив ${spanText(span, window.start, window.end)}` : null;
  let note = verdicts.map((v) => v.why).join(' · ');
  if (!note) note = tideNote;
  else if (tideNote && `${note} · ${tideNote}`.length <= 60) note = `${note} · ${tideNote}`;

  return { rating, note, tideOk: span ? tideOk : () => false };
}

/**
 * Everything render.cjs needs, plus a one-line summary, from the three
 * sources. Pure: no network, no files.
 */
function buildForecast({ area, spots, date, marine, wind, tides }) {
  const waveH = hourlySeries(marine, 'wave_height');
  const wavePeriod = hourlySeries(marine, 'wave_period');
  const windSpeed = hourlySeries(wind, 'wind_speed_10m');
  const windDir = hourlySeries(wind, 'wind_direction_10m');

  const [w0, w1] = area.window_hours;
  const sunrise = tides.sunrise ? Math.ceil(tides.sunrise.h / STEP_H - 1e-9) * STEP_H : w0;
  const start = round2(Math.max(w0, sunrise));
  const end = w1;
  if (start >= end) throw new Error(`no daylight in the ${w0}:00–${w1}:00 window (sunrise ${tides.sunrise.t})`);
  const window = { start, end, grid: grid(start, end) };

  const tideAt = (h) => interpolate(tides.tidePoints, h);
  const mid = (start + end) / 2;
  // Unrounded: the rules compare these and every label rounds them once —
  // 11.475 s shown as round(round1(…)) would read 12.
  const hm = interpolate(waveH, mid);
  const period = interpolate(wavePeriod, mid);

  const hours = [];
  for (let h = w0; h <= w1; h++) hours.push(h);
  const at = (series, h) => {
    const p = series.find((x) => x.h === h);
    if (!p) throw new Error(`Open-Meteo has no ${h}:00 value`);
    return p.v;
  };
  const dirs = hours.map((h) => at(windDir, h));
  const offshore = dirs.map((d) => isOffshore(d, area.shore_facing_deg));
  const offshoreAt = (h) => offshore[Math.min(hours.length - 1, Math.max(0, Math.floor(h) - w0))];

  // Rate every spot in reach; the canvas holds three cards, so show the best
  // three — a better colour first, the nearer within a colour.
  const ranked = spots
    .map((spot) => ({ spot, ...rateSpot(spot, { tideAt, window, hm, period }) }))
    .sort((a, b) => RANK[a.rating] - RANK[b.rating] || (a.spot.distance_km ?? 0) - (b.spot.distance_km ?? 0));
  // Red spots stay off the picture; the summary still names them.
  const rated = ranked.filter((r) => r.rating !== 'red').slice(0, 3);
  const others = ranked.filter((r) => !rated.includes(r));

  const best = longestRun(window.grid, (h) => offshoreAt(h) && rated.some((r) => r.rating !== 'red' && r.tideOk(h)));

  const labels = [...new Set(dirs.map(compass))].join('/');
  let windState;
  if (offshore.every(Boolean)) windState = 'оффшор всё утро';
  else if (!offshore.some(Boolean)) windState = 'оншор';
  else if (offshore[0]) windState = `оффшор до ${hhmm(hours[offshore.indexOf(false)])}`;
  else if (offshore[offshore.length - 1]) windState = `оффшор с ${hhmm(hours[offshore.indexOf(true)])}`;
  else windState = 'ветер переменный';

  const [, mm, dd] = date.split('-').map(Number);
  const params = {
    title: `${area.title} · ${dd} ${MONTHS[mm - 1]} · УТРО`,
    byline: 'by Jarvis',
    tidePoints: tides.tidePoints,
    tideMarkers: tides.tideMarkers,
    tideRange: tides.tideRange,
    ...(best ? { bestWindow: { startH: best.a, endH: best.b, label: 'лучшее окно' } } : {}),
    waveHours: hours,
    waveH: hours.map((h) => round2(at(waveH, h))),
    windSpeed: hours.map((h) => Math.round(at(windSpeed, h))),
    windDir: dirs.map(compass),
    windOffshore: offshore,
    waveFooter: `период ${Math.round(period)} с  ·  ${labels} ${windState}`,
    spots: rated.map(({ spot, rating, note }) => ({
      name: spot.name,
      rating,
      h: `${round1(hm).toFixed(1)} м`,
      p: `${Math.round(period)} с`,
      hm: round2(hm),
      t: Math.round(period),
      note,
    })),
    ...(rated.length === 0 ? { spotsNote: 'рядом ничего рабочего' } : {}),
    footer: best ? `окно ${hhmm(best.a)}–${hhmm(best.b)}` : 'окна нет',
    sources: 'Open-Meteo · surf-forecast.com (приливы)',
  };

  const ratingRu = { green: 'зелёный', yellow: 'жёлтый', red: 'красный' };
  const describe = (r) => {
    const away = r.spot.distance_km != null ? `, ${round1(r.spot.distance_km)} км` : '';
    return `${r.spot.name}${away} — ${ratingRu[r.rating]} (${r.note})`;
  };
  const extremes = tides.extremes
    .map((e) => `${e.type === 'high' ? 'полная' : 'малая'} вода ${e.t} ${round1(e.v)} м`)
    .join(', ');
  const summary =
    `${area.name}, ${dd} ${MONTHS[mm - 1].toLowerCase()}, утро: ` +
    `${best ? `окно ${hhmm(best.a)}–${hhmm(best.b)}` : 'хорошего окна нет'}; ` +
    `волна ${round1(hm)} м, период ${Math.round(period)} с; ветер ${labels} ${windState}; ` +
    `прилив: ${extremes}. ` +
    (rated.length ? `${rated.map(describe).join('; ')}.` : 'Рабочих спотов рядом нет.') +
    // Off the picture but in reach — so "and Berawa?" has an answer.
    (others.length ? ` Ещё рядом: ${others.map(describe).join('; ')}.` : '');

  return { params, summary };
}

/** Today in `tz` before 08:00, tomorrow after. */
function pickDate(now, tz) {
  const parts = Object.fromEntries(
    new Intl.DateTimeFormat('en-CA', {
      timeZone: tz,
      year: 'numeric',
      month: '2-digit',
      day: '2-digit',
      hour: '2-digit',
      hourCycle: 'h23',
    })
      .formatToParts(now)
      .map((p) => [p.type, p.value]),
  );
  const today = `${parts.year}-${parts.month}-${parts.day}`;
  if (Number(parts.hour) < 8) return today;
  const d = new Date(`${today}T00:00:00Z`);
  d.setUTCDate(d.getUTCDate() + 1);
  return d.toISOString().slice(0, 10);
}

function parseArgs(argv) {
  const args = {};
  for (let i = 0; i < argv.length; i++) {
    const key = argv[i].replace(/^--/, '');
    if (key === 'check') {
      args.check = true;
      continue;
    }
    if (!['lat', 'lon', 'area', 'date', 'out', 'spots'].includes(key) || argv[i + 1] === undefined) {
      throw new Error(`unknown or empty option ${argv[i]}`);
    }
    args[key] = argv[++i];
  }
  return args;
}

/** {lat, lon} from two raw strings, or null when either is missing or not a number. */
function readPosition(rawLat, rawLon) {
  if (rawLat == null || rawLon == null || String(rawLat).trim() === '' || String(rawLon).trim() === '') return null;
  const lat = Number(rawLat);
  const lon = Number(rawLon);
  return Number.isFinite(lat) && Number.isFinite(lon) ? { lat, lon } : null;
}

async function fetchJson(url) {
  const res = await fetch(url, { signal: AbortSignal.timeout(20_000) });
  const body = await res.json().catch(() => null);
  if (!res.ok || !body || body.error)
    throw new Error(`${url} → ${body && body.reason ? body.reason : `HTTP ${res.status}`}`);
  return body;
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const catalog = loadCatalog(args.spots || PERSON_SPOTS);
  if (args.check) {
    const areas = Object.keys(catalog.areas);
    console.log(`ok: ${catalog.spots.length} spots in ${areas.length} areas (${areas.join(', ')})`);
    return;
  }
  const tz = process.env.OWNER_TZ || process.env.TZ || '';

  // Where the person is: the position given, else the centre of the asked (or
  // the time zone's) area.
  // An explicit --area wins over the phone: "the forecast for Ericeira" asked from Bali.
  const position = args.area
    ? null
    : readPosition(args.lat ?? process.env.DEVICE_LAT, args.lon ?? process.env.DEVICE_LON);
  let at;
  if (position) {
    at = position;
  } else {
    const key = args.area || catalog.default_area_by_tz[tz];
    const centre = key && catalog.areas[key];
    if (!centre) {
      throw new Error(
        `no position and no area${key ? ` "${key}"` : ` for time zone "${tz}"`} — pass --lat/--lon or --area (${Object.keys(catalog.areas).join(', ')})`,
      );
    }
    at = { lat: centre.lat, lon: centre.lon };
  }
  const { areaKey, area, spots } = pickSpots(catalog, at);

  const date = args.date || pickDate(new Date(), area.tz);
  if (!/^\d{4}-\d{2}-\d{2}$/.test(date)) throw new Error(`bad --date ${date}`);

  const q = `latitude=${area.lat}&longitude=${area.lon}&timezone=${encodeURIComponent(area.tz)}&start_date=${date}&end_date=${date}`;
  const [marine, wind, tides] = await Promise.all([
    fetchJson(`https://marine-api.open-meteo.com/v1/marine?${q}&hourly=wave_height,wave_period`),
    fetchJson(`https://api.open-meteo.com/v1/forecast?${q}&hourly=wind_speed_10m,wind_direction_10m`),
    loadTides(area.tide_url, date),
  ]);
  const { params, summary } = buildForecast({ area, spots, date, marine, wind, tides });

  const outDir = args.out || '/workspace/agent/scratch';
  fs.mkdirSync(outDir, { recursive: true });
  const base = path.join(outDir, `surf_${areaKey}_${date}`);
  fs.writeFileSync(`${base}.json`, JSON.stringify(params));
  execFileSync(process.execPath, [path.join(__dirname, 'render.cjs'), `${base}.json`, `${base}.jpg`], {
    stdio: ['ignore', 'ignore', 'pipe'],
    env: {
      ...process.env,
      NODE_PATH: [process.env.NODE_PATH, '/workspace/agent/node_modules'].filter(Boolean).join(':'),
    },
    timeout: 60_000,
  });
  const result = { photo: `${base}.jpg`, params: `${base}.json`, summary };
  fs.writeFileSync(path.join(outDir, 'surf_last.json'), JSON.stringify({ ...result, area: areaKey, date }));
  console.log(JSON.stringify(result));
}

if (require.main === module) {
  main().catch((err) => {
    console.error(`forecast.cjs: ${err.message}`);
    process.exit(1);
  });
}

module.exports = { buildForecast, pickSpots, pickDate, compass, isOffshore };
