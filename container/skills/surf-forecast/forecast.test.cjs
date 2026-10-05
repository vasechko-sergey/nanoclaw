// Run: node --test container/skills/surf-forecast/forecast.test.cjs container/skills/surf-forecast/tides.test.cjs
'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const { buildForecast, pickSpots, pickDate, compass, isOffshore } = require('./forecast.cjs');
const { parseFcgon, tidesForDate } = require('./tides.cjs');

const fixture = (name) => fs.readFileSync(path.join(__dirname, 'fixtures', name), 'utf8');
const catalog = JSON.parse(fs.readFileSync(path.join(__dirname, 'spots.json'), 'utf8'));

const CANGGU_CENTRE = { lat: -8.65, lon: 115.13 };
const FINNS_BERAWA = { lat: -8.667, lon: 115.1394 };

// The real sources for Canggu, 2026-10-06: high tide all morning (1.4–1.8 m).
const sources = {
  date: '2026-10-06',
  marine: JSON.parse(fixture('canggu-marine-2026-10-06.json')),
  wind: JSON.parse(fixture('canggu-wind-2026-10-06.json')),
  tides: tidesForDate(parseFcgon(fixture('canggu-tides-2026-10-05.html')), '2026-10-06'),
};
const forecastAt = (at, over = {}) => buildForecast({ ...pickSpots(catalog, at), ...sources, ...over });
const shown = ({ params }) => params.spots.map((s) => `${s.name} ${s.rating}`);

// The same day with the tide swapped for a flat one.
function flatTide(v) {
  const tidePoints = Array.from({ length: 25 }, (_, h) => ({ h, v }));
  return { ...sources.tides, tidePoints, sunrise: { h: 6, t: '06:00' } };
}
function swell(height, period) {
  const hourly = { ...sources.marine.hourly };
  hourly.wave_height = hourly.wave_height.map(() => height);
  hourly.wave_period = hourly.wave_period.map(() => period);
  return { ...sources.marine, hourly };
}

test('picks every spot within reach of the person, of one area, nearest first', () => {
  const fromCentre = pickSpots(catalog, CANGGU_CENTRE);
  assert.equal(fromCentre.areaKey, 'canggu');
  assert.deepEqual(
    fromCentre.spots.map((s) => s.name),
    ['Echo Beach', 'Pererenan', "Old Man's", 'Batu Bolong', 'Berawa'],
  );
  assert.deepEqual(
    pickSpots(catalog, FINNS_BERAWA).spots.map((s) => s.name),
    ['Berawa', "Old Man's", 'Batu Bolong', 'Echo Beach', 'Pererenan'],
  );
  assert.equal(pickSpots(catalog, { lat: 38.99, lon: -9.42 }).areaKey, 'ericeira');
});

test('says how far the nearest known spot is when none is within reach', () => {
  // Uluwatu: Bali, same time zone as Canggu, but none of these spots is near.
  assert.throws(
    () => pickSpots(catalog, { lat: -8.8149, lon: 115.0884 }),
    /no known spot within 6 km — the nearest is .+, 1\d\.\d km/,
  );
});

test('a real high-tide morning: the three nearest greens; Berawa (0.8–1.4 m) is yellow and drops out', () => {
  const f = forecastAt(CANGGU_CENTRE);
  assert.equal(f.params.title, 'КАНГУ · 6 ОКТЯБРЯ · УТРО');
  assert.deepEqual(shown(f), ['Echo Beach green', 'Pererenan green', "Old Man's green"]);
  assert.deepEqual(f.params.spots[0], {
    name: 'Echo Beach',
    rating: 'green',
    h: '1.2 м',
    p: '11 с',
    hm: 1.24,
    t: 11,
    note: 'прилив всё утро',
  });
  assert.deepEqual(f.params.windDir, ['NE', 'NE', 'E', 'E', 'SE']); // 60°, 67°, 73°, 89°, 116°
  assert.deepEqual(f.params.bestWindow, { startH: 6, endH: 9, label: 'лучшее окно' }); // sunrise 06:00
  assert.equal(f.params.footer, 'окно 06:00–09:00');
  assert.equal(f.params.waveFooter, 'период 11 с  ·  NE/E/SE оффшор всё утро');
  assert.match(f.summary, /^Кангу, 6 октября, утро: окно 06:00–09:00; волна 1\.2 м, период 11 с/);
  assert.match(f.summary, /Echo Beach, 0\.8 км — зелёный \(прилив всё утро\)/);
});

test('from Berawa on a low tide, Berawa leads and the reefs follow, nearest first', () => {
  const f = forecastAt(FINNS_BERAWA, { tides: flatTide(0.9) });
  assert.deepEqual(shown(f), ['Berawa green', "Old Man's yellow", 'Batu Bolong yellow']);
  assert.equal(f.params.spots[1].note, 'прилив до 0.9 м — мелко');
});

test('from Berawa on the real high tide, Berawa is yellow and the nearest greens are shown', () => {
  const f = forecastAt(FINNS_BERAWA);
  assert.deepEqual(shown(f), ["Old Man's green", 'Batu Bolong green', 'Echo Beach green']);
  // Off the picture, still in the summary — for "and Berawa?".
  assert.match(
    f.summary,
    /Ещё рядом: Pererenan, 2\.6 км — зелёный \(прилив всё утро\); Berawa, 0 км — жёлтый \(прилив 1\.4–1\.8 м, нужно 0\.8–1\.4\)\.$/,
  );
});

test('a tide that only touches the band at the end of the window does not count', () => {
  // Berawa's band ends at 1.4 m; the real tide reaches it only at 09:00.
  const berawa = buildForecast({
    ...sources,
    area: catalog.areas.canggu,
    spots: [catalog.spots.find((s) => s.name === 'Berawa')],
  });
  assert.equal(berawa.params.spots[0].rating, 'yellow');
  assert.equal(berawa.params.spots[0].note, 'прилив 1.4–1.8 м, нужно 0.8–1.4');
});

test('low tide all morning: yellow above 0.5 m under the band, red below, no window', () => {
  assert.equal(forecastAt(CANGGU_CENTRE, { tides: flatTide(0.7) }).params.spots[0].rating, 'yellow');
  const red = forecastAt(CANGGU_CENTRE, { tides: flatTide(0.2) });
  assert.deepEqual(
    red.params.spots.map((s) => s.rating),
    ['red', 'red', 'red'],
  );
  assert.equal(red.params.bestWindow, undefined);
  assert.equal(red.params.footer, 'окна нет');
});

test('a falling tide gives the time it stays workable', () => {
  // 1.4 m at 06:00 falling 0.2 m an hour: under 1.0 m after 08:00.
  const tidePoints = Array.from({ length: 25 }, (_, h) => ({ h, v: 2.6 - 0.2 * h }));
  const f = forecastAt(CANGGU_CENTRE, { tides: { ...sources.tides, tidePoints } });
  assert.equal(f.params.spots[0].note, 'прилив до 08:00');
  assert.equal(f.params.footer, 'окно 06:00–08:00');
});

test('short period and small swell: one miss is yellow, two are red', () => {
  const one = forecastAt(CANGGU_CENTRE, { marine: swell(1.3, 9.4) });
  // Echo needs 9 s and stays green; the 10 s reefs go yellow.
  assert.deepEqual(shown(one), ['Echo Beach green', 'Pererenan yellow', "Old Man's yellow"]);
  assert.equal(one.params.spots[1].note, 'период 9 с, нужно от 10 · прилив всё утро');
  const two = forecastAt(CANGGU_CENTRE, { marine: swell(0.7, 9.4) });
  assert.equal(two.params.spots[2].rating, 'red');
});

test('the date: today before 08:00 local, tomorrow from 08:00', () => {
  // 2026-10-05 23:30 UTC = 2026-10-06 07:30 in Bali.
  assert.equal(pickDate(new Date('2026-10-05T23:30:00Z'), 'Asia/Makassar'), '2026-10-06');
  // 2026-10-06 00:30 UTC = 08:30 in Bali.
  assert.equal(pickDate(new Date('2026-10-06T00:30:00Z'), 'Asia/Makassar'), '2026-10-07');
  // 2026-10-04 13:30 UTC = 21:30 in Bali: the request that started all this.
  assert.equal(pickDate(new Date('2026-10-04T13:30:00Z'), 'Asia/Makassar'), '2026-10-05');
});

test('wind: the skill’s compass table and the 67.5° offshore cone', () => {
  assert.deepEqual([22, 23, 67, 68, 112, 113, 337, 338].map(compass), ['N', 'NE', 'NE', 'E', 'E', 'SE', 'NW', 'N']);
  // A west-facing beach (270°) is offshore in wind from 22.5°–157.5°.
  assert.deepEqual(
    [20, 25, 90, 155, 160, 270].map((d) => isOffshore(d, 270)),
    [false, true, true, true, false, false],
  );
});
