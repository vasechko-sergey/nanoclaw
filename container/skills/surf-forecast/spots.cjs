#!/usr/bin/env node
/**
 * The only way the agent changes the surf spot catalogue. Every write is
 * checked against the contract in catalog.cjs and refused whole when it
 * doesn't hold, so the file can't drift from what forecast.cjs reads.
 *
 *   node spots.cjs show [<spot>]                 the catalogue, or one spot in full
 *   node spots.cjs fields                        the contract: every field, its format, what it does
 *   node spots.cjs set <spot> <field>=<value>…   change a spot ("1.0-1.9", "1.0-" = no upper bound)
 *   node spots.cjs add <name> <field>=<value>…   a new spot, every required field given
 *   node spots.cjs remove <spot>
 *   node spots.cjs area <key> <field>=<value>…   change an area; a new key adds one
 *   node spots.cjs check                         validate the file
 * Option: --file <path> (default: the person's catalogue). `<field>=-` drops an optional field.
 */
'use strict';

const { AREA_FIELDS, SPOT_FIELDS, PERSON_SPOTS, loadCatalog, saveCatalog } = require('./catalog.cjs');

/** A command-line value → the field's JSON value, or throws with the expected form. */
function parseValue(field, spec, raw) {
  const text = String(raw).trim();
  if (text === '-' || text === 'null' || text === '') {
    if (spec.required) throw new Error(`${field}: обязательное поле, убрать нельзя`);
    return undefined;
  }
  const number = (s) => {
    const n = Number(String(s).replace(',', '.'));
    if (!Number.isFinite(n)) throw new Error(`${field}: «${s}» — не число`);
    return n;
  };
  switch (spec.kind) {
    case 'number':
      return number(text);
    case 'band': {
      const m = text.match(/^([\d.,]+)\s*[-–—]\s*([\d.,]*|null)$/);
      if (!m) throw new Error(`${field}: нужно «низ-верх», например 1.0-1.9, или «1.0-» без верха`);
      return [number(m[1]), m[2] === '' || m[2] === 'null' ? null : number(m[2])];
    }
    case 'hours': {
      const m = text.match(/^(\d{1,2})\s*[-–—]\s*(\d{1,2})$/);
      if (!m) throw new Error(`${field}: нужно «с-до» в целых часах, например 5-9`);
      return [Number(m[1]), Number(m[2])];
    }
    default:
      return text;
  }
}

/** ["k=v", …] → [[field, value], …], each field known to `fields`. */
function parseAssignments(pairs, fields) {
  if (pairs.length === 0) throw new Error('нечего менять: укажи поле=значение');
  return pairs.map((pair) => {
    const eq = pair.indexOf('=');
    if (eq <= 0) throw new Error(`«${pair}»: нужно поле=значение`);
    const field = pair.slice(0, eq).trim();
    const spec = fields[field];
    if (!spec)
      throw new Error(
        `${field}: такого поля нет в контракте (есть: ${Object.keys(fields).join(', ')}; заметки — в about)`,
      );
    return [field, parseValue(field, spec, pair.slice(eq + 1))];
  });
}

function apply(obj, assignments) {
  for (const [field, value] of assignments) {
    if (value === undefined) delete obj[field];
    else obj[field] = value;
  }
}

function findSpot(catalog, name) {
  const i = catalog.spots.findIndex((s) => s.name.toLowerCase() === String(name).trim().toLowerCase());
  if (i < 0) throw new Error(`спота «${name}» нет (есть: ${catalog.spots.map((s) => s.name).join(', ')})`);
  return i;
}

function spotLine(s) {
  const [lo, hi] = s.ideal_tide_m;
  const swell = `волна от ${s.min_swell_m}${s.max_swell_m != null ? ` до ${s.max_swell_m}` : ''} м`;
  return `${s.name} [${s.area}, ${s.type}] прилив ${lo}–${hi ?? '∞'} м · период от ${s.min_period_s} с · ${swell}`;
}

function fieldsText() {
  const block = (title, fields) =>
    [
      title,
      ...Object.entries(fields).map(
        ([k, f]) =>
          `  ${k}${f.required ? '' : ' (необязательно)'}${f.rated ? '' : ' [на рейтинг не влияет]'} — ${f.about}`,
      ),
    ].join('\n');
  return `${block('Спот (spots.cjs set/add):', SPOT_FIELDS)}\n\n${block('Район (spots.cjs area):', AREA_FIELDS)}`;
}

function run(argv) {
  const fileFlag = argv.indexOf('--file');
  const file = fileFlag >= 0 ? argv[fileFlag + 1] : PERSON_SPOTS;
  const args = fileFlag >= 0 ? argv.filter((_, i) => i !== fileFlag && i !== fileFlag + 1) : argv;
  const [command, target, ...rest] = args;

  if (command === 'fields') return fieldsText();
  const catalog = loadCatalog(file);

  switch (command) {
    case 'check':
      return `ok: ${catalog.spots.length} спотов, районы: ${Object.keys(catalog.areas).join(', ')}`;
    case 'show':
      if (target) return JSON.stringify(catalog.spots[findSpot(catalog, target)], null, 2);
      return catalog.spots.map(spotLine).join('\n');
    case 'set': {
      const i = findSpot(catalog, target);
      apply(catalog.spots[i], parseAssignments(rest, SPOT_FIELDS));
      saveCatalog(catalog, file);
      return `ok: ${spotLine(catalog.spots[i])}`;
    }
    case 'add': {
      if (!target) throw new Error('add <имя> поле=значение…');
      const spot = { name: target.trim() };
      apply(spot, parseAssignments(rest, SPOT_FIELDS));
      catalog.spots.push(spot);
      saveCatalog(catalog, file);
      return `ok: ${spotLine(spot)}`;
    }
    case 'remove': {
      const [gone] = catalog.spots.splice(findSpot(catalog, target), 1);
      saveCatalog(catalog, file);
      return `ok: убран ${gone.name}`;
    }
    case 'area': {
      if (!target) throw new Error('area <ключ> поле=значение…');
      const area = catalog.areas[target] || (catalog.areas[target] = {});
      apply(area, parseAssignments(rest, AREA_FIELDS));
      saveCatalog(catalog, file);
      return `ok: ${target} — ${JSON.stringify(area)}`;
    }
    default:
      throw new Error('команды: show, fields, set, add, remove, area, check');
  }
}

if (require.main === module) {
  try {
    console.log(run(process.argv.slice(2)));
  } catch (err) {
    console.error(`spots.cjs: ${err.message}`);
    process.exit(1);
  }
}

module.exports = { run, parseValue };
