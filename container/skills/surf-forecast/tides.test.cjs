// Run: node --test container/skills/surf-forecast/
'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const { parseFcgon, tidesForDate } = require('./tides.cjs');

// The real Canggu tide page of 2026-10-05, cut to three days.
const page = fs.readFileSync(path.join(__dirname, 'fixtures', 'canggu-tides-2026-10-05.html'), 'utf8');

test('reads the day in metres above chart datum, as surf-forecast.com shows it', () => {
  const t = tidesForDate(parseFcgon(page), '2026-10-06');
  assert.equal(t.hourly.length, 24);
  assert.deepEqual(t.hourly[0], { h: 0, v: 1.394 });
  assert.deepEqual(t.hourly[8], { h: 8, v: 1.579 });
  assert.deepEqual(
    t.extremes.map((e) => `${e.type} ${e.t} ${e.v}`),
    ['high 05:11 1.83', 'low 12:58 0.83', 'high 19:53 1.65'],
  );
});

test('gives render.cjs its tide fields, with one point either side of the day', () => {
  const t = tidesForDate(parseFcgon(page), '2026-10-06');
  assert.equal(t.tidePoints.length, 26);
  assert.deepEqual(t.tidePoints[0], { h: -1, v: 1.331 }); // 23:00 on the 5th
  assert.deepEqual(t.tidePoints[25], { h: 24, v: 1.25 }); // 00:00 on the 7th
  assert.deepEqual(t.tideMarkers[0], { h: 5.18, v: 1.83, t: '05:11', val: '1.8 м', above: true });
  assert.equal(t.tideMarkers[1].above, false); // a low's label goes under the curve
});

test('names the dates the page has when the asked one is missing', () => {
  assert.throws(() => tidesForDate(parseFcgon(page), '2026-11-01'), /2026-10-05 … 2026-10-07/);
});

test('says so when the page carries no tide table', () => {
  assert.throws(() => parseFcgon('<html>Access denied</html>'), /no window\.FCGON/);
});
