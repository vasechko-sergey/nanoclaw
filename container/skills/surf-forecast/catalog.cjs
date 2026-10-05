/**
 * The surf spot catalogue and its contract — the one definition that
 * forecast.cjs reads, spots.cjs edits through, and `spots.cjs fields` prints.
 * Nothing else may describe the fields, so the agent's edits, the docs and
 * the script can't drift apart.
 *
 * The catalogue is the person's (/workspace/agent/memories/self/surf-spots.json),
 * seeded from this skill's spots.json. It is strict: an unknown field is an
 * error, not a silently ignored wish — what the rating doesn't use goes into
 * a spot's `about`. `version` names the contract the file was written for.
 */
'use strict';

const fs = require('node:fs');
const path = require('node:path');

const CATALOG_VERSION = 1;
const PERSON_SPOTS = '/workspace/agent/memories/self/surf-spots.json';
const DEFAULT_SPOTS = path.join(__dirname, 'spots.json');

/**
 * kind: number | text | url | enum | hours | band | area
 * rated: the forecast reads it (the rest is for people and lookups).
 */
const AREA_FIELDS = {
  title: { kind: 'text', required: true, about: 'заголовок картинки, капслоком: «КАНГУ»' },
  name: { kind: 'text', required: true, about: 'имя района в сводке: «Кангу»' },
  tz: { kind: 'text', required: true, about: 'часовой пояс IANA: Asia/Makassar' },
  lat: { kind: 'number', required: true, rated: true, about: 'широта точки, где берутся волна и ветер' },
  lon: { kind: 'number', required: true, rated: true, about: 'долгота той же точки' },
  shore_facing_deg: {
    kind: 'number',
    required: true,
    rated: true,
    min: 0,
    max: 360,
    about: 'куда смотрит берег, градусы; оффшор — ветер с противоположной стороны ±67.5°',
  },
  window_hours: { kind: 'hours', required: true, rated: true, about: 'утреннее окно «с-до», целые часы: 5-9' },
  tide_url: { kind: 'url', required: true, rated: true, about: 'страница приливов surf-forecast.com …/tides/latest' },
  msl_offset_m: {
    kind: 'number',
    required: false,
    about: 'поправка Open-Meteo к таблице приливов, м — только для запасного пути без surf-forecast.com',
  },
};

const SPOT_FIELDS = {
  name: { kind: 'text', required: true, about: 'имя спота, уникальное' },
  area: { kind: 'area', required: true, rated: true, about: 'ключ района из areas: canggu' },
  lat: { kind: 'number', required: true, rated: true, about: 'широта спота (по ней ищутся споты рядом)' },
  lon: { kind: 'number', required: true, rated: true, about: 'долгота спота' },
  type: {
    kind: 'enum',
    values: ['reef', 'beach', 'point'],
    required: true,
    rated: true,
    about: 'reef | beach | point; beach из-за прилива не бывает хуже жёлтого',
  },
  ideal_tide_m: {
    kind: 'band',
    required: true,
    rated: true,
    about: 'рабочий прилив «низ-верх», м над нулём глубин: 1.0-1.9; «1.0-» — без верха',
  },
  min_period_s: {
    kind: 'number',
    required: true,
    rated: true,
    min: 0,
    about: 'период не короче, с (на 1 с короче — жёлтый)',
  },
  min_swell_m: {
    kind: 'number',
    required: true,
    rated: true,
    min: 0,
    about: 'волна не ниже, м (ниже — жёлтый, ниже 0.5 — красный)',
  },
  max_swell_m: { kind: 'number', required: false, rated: true, min: 0, about: 'волна не выше, м (выше — жёлтый)' },
  about: { kind: 'text', required: false, about: 'всё остальное о споте — для людей, на рейтинг не влияет' },
};

const TOP_FIELDS = ['version', 'reach_km', 'default_area_by_tz', 'areas', 'spots'];

const isNum = (v) => typeof v === 'number' && Number.isFinite(v);

/** Problems of one value against its field spec, or null. */
function checkValue(spec, v, catalog) {
  switch (spec.kind) {
    case 'number':
      if (!isNum(v)) return 'число';
      if (spec.min != null && v < spec.min) return `не меньше ${spec.min}`;
      if (spec.max != null && v > spec.max) return `не больше ${spec.max}`;
      return null;
    case 'text':
      return typeof v === 'string' && v.trim() ? null : 'непустой текст';
    case 'url':
      return typeof v === 'string' && /^https?:\/\//.test(v) ? null : 'адрес http(s)';
    case 'enum':
      return spec.values.includes(v) ? null : `одно из: ${spec.values.join(', ')}`;
    case 'area':
      return catalog.areas && Object.prototype.hasOwnProperty.call(catalog.areas, v)
        ? null
        : `ключ района из areas (${Object.keys(catalog.areas || {}).join(', ')})`;
    case 'hours':
      return Array.isArray(v) && v.length === 2 && v.every(Number.isInteger) && v[0] >= 0 && v[1] <= 23 && v[0] < v[1]
        ? null
        : '[с, до] целые часы 0–23, «с» раньше «до»';
    case 'band':
      return Array.isArray(v) && v.length === 2 && isNum(v[0]) && (v[1] === null || (isNum(v[1]) && v[1] > v[0]))
        ? null
        : '[низ, верх] в метрах, верх выше низа или null';
    default:
      return `неизвестный вид поля ${spec.kind}`;
  }
}

function checkObject(where, obj, fields, catalog, errors) {
  if (!obj || typeof obj !== 'object' || Array.isArray(obj)) {
    errors.push(`${where}: не объект`);
    return;
  }
  for (const key of Object.keys(obj)) {
    if (!fields[key]) {
      errors.push(
        `${where}.${key}: такого поля нет в контракте (есть: ${Object.keys(fields).join(', ')}; заметки — в about)`,
      );
    }
  }
  for (const [key, spec] of Object.entries(fields)) {
    const v = obj[key];
    if (v === undefined || v === null) {
      if (spec.required) errors.push(`${where}.${key}: обязательно — ${spec.about}`);
      continue;
    }
    const problem = checkValue(spec, v, catalog);
    if (problem) errors.push(`${where}.${key}: нужно ${problem}, а стоит ${JSON.stringify(v)}`);
  }
}

/** Every way `c` breaks the contract, as "where: what" lines; [] when it holds. */
function validateCatalog(c) {
  const errors = [];
  if (!c || typeof c !== 'object' || Array.isArray(c)) return ['каталог: не JSON-объект'];
  for (const key of Object.keys(c)) {
    if (!TOP_FIELDS.includes(key)) errors.push(`${key}: такого поля нет в контракте (есть: ${TOP_FIELDS.join(', ')})`);
  }
  if (c.version !== CATALOG_VERSION) {
    errors.push(`version: каталог для контракта ${JSON.stringify(c.version)}, скрипт знает ${CATALOG_VERSION}`);
  }
  if (!isNum(c.reach_km) || c.reach_km <= 0) errors.push('reach_km: сколько км считать «рядом», число больше 0');
  if (c.default_area_by_tz != null) {
    for (const [tz, key] of Object.entries(c.default_area_by_tz)) {
      if (!c.areas || !c.areas[key]) errors.push(`default_area_by_tz.${tz}: района «${key}» нет в areas`);
    }
  }
  if (!c.areas || typeof c.areas !== 'object' || Object.keys(c.areas).length === 0) {
    errors.push('areas: нужен хотя бы один район');
  } else {
    for (const [key, a] of Object.entries(c.areas)) checkObject(`areas.${key}`, a, AREA_FIELDS, c, errors);
  }
  if (!Array.isArray(c.spots) || c.spots.length === 0) {
    errors.push('spots: нужен хотя бы один спот');
  } else {
    const seen = new Set();
    c.spots.forEach((sp, i) => {
      const where = `spots[${i}]${sp && sp.name ? ` (${sp.name})` : ''}`;
      checkObject(where, sp, SPOT_FIELDS, c, errors);
      if (sp && typeof sp.name === 'string') {
        const k = sp.name.trim().toLowerCase();
        if (seen.has(k)) errors.push(`${where}.name: спот с таким именем уже есть`);
        seen.add(k);
      }
      if (sp && isNum(sp.max_swell_m) && isNum(sp.min_swell_m) && sp.max_swell_m <= sp.min_swell_m) {
        errors.push(`${where}.max_swell_m: должна быть больше min_swell_m (${sp.min_swell_m})`);
      }
    });
  }
  return errors;
}

/**
 * The person's catalogue; on first use a copy of the skill's defaults.
 * Throws with every problem when the file breaks the contract.
 */
function loadCatalog(file = PERSON_SPOTS, defaults = DEFAULT_SPOTS) {
  if (!fs.existsSync(file)) {
    fs.mkdirSync(path.dirname(file), { recursive: true });
    fs.writeFileSync(file, fs.readFileSync(defaults, 'utf8'));
    console.error(`catalog: seeded ${file} from the skill defaults`);
  }
  let catalog;
  try {
    catalog = JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch (err) {
    throw new Error(`${file}: не JSON — ${err.message}`);
  }
  const errors = validateCatalog(catalog);
  if (errors.length) throw new Error(`${file} не сходится с контрактом: ${errors.join('; ')}`);
  return catalog;
}

/** Write `catalog` only if it holds the contract; atomic, so a crash leaves the old file. */
function saveCatalog(catalog, file = PERSON_SPOTS) {
  const errors = validateCatalog(catalog);
  if (errors.length) throw new Error(`не записано — ${errors.join('; ')}`);
  const tmp = `${file}.tmp-${process.pid}`;
  fs.writeFileSync(tmp, `${JSON.stringify(catalog, null, 2)}\n`);
  fs.renameSync(tmp, file);
}

module.exports = {
  CATALOG_VERSION,
  PERSON_SPOTS,
  DEFAULT_SPOTS,
  AREA_FIELDS,
  SPOT_FIELDS,
  validateCatalog,
  loadCatalog,
  saveCatalog,
};
