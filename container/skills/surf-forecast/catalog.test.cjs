// Run: node --test container/skills/surf-forecast/catalog.test.cjs
'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const {
  CATALOG_VERSION,
  SPOT_FIELDS,
  AREA_FIELDS,
  DEFAULT_SPOTS,
  validateCatalog,
  loadCatalog,
} = require('./catalog.cjs');
const { run } = require('./spots.cjs');
const { pickSpots } = require('./forecast.cjs');

const defaults = () => JSON.parse(fs.readFileSync(DEFAULT_SPOTS, 'utf8'));

/** A fresh copy of the defaults as the person's catalogue; returns its path. */
function personFile() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'surf-spots-'));
  const file = path.join(dir, 'surf-spots.json');
  fs.copyFileSync(DEFAULT_SPOTS, file);
  return file;
}
const read = (file) => JSON.parse(fs.readFileSync(file, 'utf8'));
const spot = (file, name) => read(file).spots.find((s) => s.name === name);

test('the shipped defaults hold the contract, at the version the script knows', () => {
  assert.deepEqual(validateCatalog(defaults()), []);
  assert.equal(defaults().version, CATALOG_VERSION);
});

test('an unknown field is an error, not a silently ignored wish', () => {
  const c = defaults();
  c.spots[0].best_swell_dir = 'SW';
  assert.match(
    validateCatalog(c).join('\n'),
    /Batu Bolong\)\.best_swell_dir: такого поля нет в контракте.*заметки — в about/,
  );
});

test('a file written for another contract version is refused', () => {
  const c = defaults();
  c.version = CATALOG_VERSION + 1;
  assert.match(validateCatalog(c).join('\n'), /version: каталог для контракта 2, скрипт знает 1/);
});

test('bands, names and areas are checked across fields', () => {
  const c = defaults();
  c.spots[0].ideal_tide_m = [1.9, 1.0];
  c.spots[1].name = 'Batu Bolong';
  c.spots[2].area = 'uluwatu';
  c.spots[3].max_swell_m = 1.0; // Echo needs 1.2 at least
  const errors = validateCatalog(c).join('\n');
  assert.match(errors, /ideal_tide_m: нужно \[низ, верх\]/);
  assert.match(errors, /name: спот с таким именем уже есть/);
  assert.match(errors, /area: нужно ключ района из areas/);
  assert.match(errors, /max_swell_m: должна быть больше min_swell_m/);
});

test('the first run seeds the person’s catalogue from the defaults', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'surf-seed-'));
  const file = path.join(dir, 'memories', 'self', 'surf-spots.json');
  const c = loadCatalog(file);
  assert.ok(fs.existsSync(file));
  assert.deepEqual(c, defaults());
});

test('set changes one spot and writes only what holds the contract', () => {
  const file = personFile();
  assert.match(
    run(['--file', file, 'set', 'batu bolong', 'ideal_tide_m=1.1-1.8', 'max_swell_m=2']),
    /^ok: Batu Bolong .* прилив 1\.1–1\.8 м .* волна от 0\.8 до 2 м/,
  );
  assert.deepEqual(spot(file, 'Batu Bolong').ideal_tide_m, [1.1, 1.8]);
  assert.equal(spot(file, 'Batu Bolong').max_swell_m, 2);
  // "1.0-" is a band without an upper bound; "-" drops an optional field.
  run(['--file', file, 'set', 'Batu Bolong', 'ideal_tide_m=1.0-', 'max_swell_m=-']);
  assert.deepEqual(spot(file, 'Batu Bolong').ideal_tide_m, [1.0, null]);
  assert.equal('max_swell_m' in spot(file, 'Batu Bolong'), false);
});

test('a refused edit leaves the file exactly as it was', () => {
  const file = personFile();
  const before = fs.readFileSync(file, 'utf8');
  assert.throws(
    () => run(['--file', file, 'set', 'Echo Beach', 'swell_dir=SW']),
    /swell_dir: такого поля нет в контракте/,
  );
  assert.throws(
    () => run(['--file', file, 'set', 'Echo Beach', 'ideal_tide_m=2.0-1.0']),
    /не записано — .*ideal_tide_m/,
  );
  assert.throws(() => run(['--file', file, 'set', 'Echo Beach', 'ideal_tide_m=высокий']), /нужно «низ-верх»/);
  assert.throws(() => run(['--file', file, 'set', 'Echo Beach', 'min_period_s=-']), /обязательное поле/);
  assert.equal(fs.readFileSync(file, 'utf8'), before);
});

test('add needs every required field, and the new spot is picked up by the forecast', () => {
  const file = personFile();
  assert.throws(
    () => run(['--file', file, 'add', 'Seminyak', 'area=canggu', 'lat=-8.6915', 'lon=115.158']),
    /не записано — .*Seminyak\)\.type: обязательно/,
  );
  run([
    '--file',
    file,
    'add',
    'Seminyak',
    'area=canggu',
    'lat=-8.6915',
    'lon=115.158',
    'type=beach',
    'ideal_tide_m=0.5-',
    'min_period_s=9',
    'min_swell_m=0.6',
    'about=beach break, мягко на среднем приливе',
  ]);
  const near = pickSpots(read(file), { lat: -8.69, lon: 115.157 });
  assert.equal(near.spots[0].name, 'Seminyak');
  run(['--file', file, 'remove', 'Seminyak']);
  assert.equal(spot(file, 'Seminyak'), undefined);
});

test('area edits go through the same contract', () => {
  const file = personFile();
  run(['--file', file, 'area', 'canggu', 'window_hours=6-10']);
  assert.deepEqual(read(file).areas.canggu.window_hours, [6, 10]);
  assert.throws(() => run(['--file', file, 'area', 'canggu', 'window_hours=10-6']), /window_hours/);
});

test('fields prints the contract itself — every spot and area field, nothing else', () => {
  const text = run(['fields']);
  for (const key of [...Object.keys(SPOT_FIELDS), ...Object.keys(AREA_FIELDS)]) {
    assert.match(text, new RegExp(`^  ${key}( \\(необязательно\\))?( \\[на рейтинг не влияет\\])? — `, 'm'));
  }
  assert.match(text, /about \(необязательно\) \[на рейтинг не влияет\] — всё остальное о споте/);
});
