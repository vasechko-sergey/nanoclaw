// Run: node --test container/skills/surf-forecast/
'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const { buildForecast, pickDate, compass, isOffshore } = require('./forecast.cjs');
const { parseFcgon, tidesForDate } = require('./tides.cjs');

const fixture = (name) => fs.readFileSync(path.join(__dirname, 'fixtures', name), 'utf8');
const canggu = JSON.parse(fs.readFileSync(path.join(__dirname, 'presets.json'), 'utf8')).spots.canggu;

// The real sources for Canggu, 2026-10-06.
const real = {
  preset: canggu,
  date: '2026-10-06',
  marine: JSON.parse(fixture('canggu-marine-2026-10-06.json')),
  wind: JSON.parse(fixture('canggu-wind-2026-10-06.json')),
  tides: tidesForDate(parseFcgon(fixture('canggu-tides-2026-10-05.html')), '2026-10-06'),
};

test('a real morning: three green reefs, the window from sunrise to 09:00', () => {
  const { params, summary } = buildForecast(real);
  assert.equal(params.title, 'КАНГУ · 6 ОКТЯБРЯ · УТРО');
  assert.deepEqual(params.waveHours, [5, 6, 7, 8, 9]);
  assert.deepEqual(params.windDir, ['NE', 'NE', 'E', 'E', 'SE']); // 60°, 67°, 73°, 89°, 116°
  assert.deepEqual(params.windOffshore, [true, true, true, true, true]);
  assert.deepEqual(params.bestWindow, { startH: 6, endH: 9, label: 'лучшее окно' }); // sunrise 06:00
  assert.equal(params.footer, 'окно 06:00–09:00');
  assert.deepEqual(
    params.spots.map((s) => `${s.name} ${s.rating} ${s.h} ${s.p} ${s.note}`),
    [
      'Batu Bolong green 1.2 м 11 с прилив всё утро',
      'Pererenan green 1.2 м 11 с прилив всё утро',
      'Echo Beach green 1.2 м 11 с прилив всё утро',
    ],
  );
  assert.equal(params.waveFooter, 'период 11 с  ·  NE/E/SE оффшор всё утро');
  assert.deepEqual(params.tideMarkers, real.tides.tideMarkers);
  assert.match(summary, /^Кангу, 6 октября, утро: окно 06:00–09:00; волна 1\.2 м, период 11 с/);
  assert.match(summary, /полная вода 05:11 1\.8 м, малая вода 12:58 0\.8 м/);
});

// Same day, tide and swell swapped for ones that break the rules.
function withTide(heights) {
  const tidePoints = heights.map((v, h) => ({ h, v }));
  return { ...real.tides, tidePoints, sunrise: { h: 6, t: '06:00' } };
}
function withSwell(height, period) {
  const hourly = { ...real.marine.hourly };
  hourly.wave_height = hourly.wave_height.map(() => height);
  hourly.wave_period = hourly.wave_period.map(() => period);
  return { ...real.marine, hourly };
}
const flat = (v) => Array.from({ length: 25 }, () => v);

test('low tide all morning: yellow above 0.5 m below the break, red under it', () => {
  const yellow = buildForecast({ ...real, tides: withTide(flat(0.7)) });
  assert.equal(yellow.params.spots[0].rating, 'yellow');
  assert.equal(yellow.params.spots[0].note, 'прилив до 0.7 м — мелко');
  const red = buildForecast({ ...real, tides: withTide(flat(0.4)) });
  assert.equal(red.params.spots[0].rating, 'red');
  assert.equal(red.params.bestWindow, undefined);
  assert.equal(red.params.footer, 'окна нет');
});

test('a falling tide gives the time it stays workable', () => {
  // 1.4 m at 06:00 falling 0.2 m an hour: under 1.0 m after 08:00.
  const heights = Array.from({ length: 25 }, (_, h) => 2.6 - 0.2 * h);
  const { params } = buildForecast({ ...real, tides: withTide(heights) });
  assert.equal(params.spots[0].note, 'прилив до 08:00');
  assert.equal(params.footer, 'окно 06:00–08:00');
});

test('only Echo Beach minds a high tide', () => {
  const { params } = buildForecast({ ...real, tides: withTide(flat(2.3)) });
  assert.equal(params.spots[0].rating, 'green'); // Batu Bolong: no upper bound
  assert.equal(params.spots[2].rating, 'yellow');
  assert.equal(params.spots[2].note, 'прилив от 2.3 м — высоко');
});

test('short period and small swell: one miss is yellow, two are red', () => {
  const one = buildForecast({ ...real, marine: withSwell(1.3, 9.4) });
  assert.equal(one.params.spots[0].rating, 'yellow'); // period 9 s for a 10 s reef
  assert.equal(one.params.spots[0].note, 'период 9 с, нужно от 10 · прилив всё утро');
  assert.equal(one.params.spots[2].rating, 'green'); // Echo needs 9 s
  const two = buildForecast({ ...real, marine: withSwell(0.7, 9.4) });
  assert.equal(two.params.spots[0].rating, 'red');
});

test('never more than three spots — the canvas holds three cards', () => {
  const preset = { ...canggu, breaks: [...canggu.breaks, ...canggu.breaks] };
  assert.equal(buildForecast({ ...real, preset }).params.spots.length, 3);
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
