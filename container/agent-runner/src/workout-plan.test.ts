/**
 * Today's workout plan without the model: Greg's readiness signal, the agent's
 * deterministic builder (scripts/build-plan.js), and the card that ships it.
 *
 * The builder is faked per test with a tiny script in a temp agent dir, run the
 * same way production runs the real one (this runtime's bun, cwd = agent dir).
 */
import { describe, it, expect, beforeEach, afterEach } from 'bun:test';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, rmSync, realpathSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { initTestSessionDb, closeSessionDb } from './db/connection.js';
import { getUndeliveredMessages } from './db/messages-out.js';
import { readinessFor, buildPlan, sendWorkoutPlan } from './workout-plan.js';

let dir: string;
beforeEach(() => {
  dir = realpathSync(mkdtempSync(join(tmpdir(), 'wp-')));
  initTestSessionDb();
});
afterEach(() => {
  closeSessionDb();
  rmSync(dir, { recursive: true, force: true });
});

function writeSignal(signal: unknown): string {
  const p = join(dir, 'signal.json');
  writeFileSync(p, typeof signal === 'string' ? signal : JSON.stringify(signal));
  return p;
}

/** A stand-in for scripts/build-plan.js whose body is the given JS. */
function writeBuilder(body: string): void {
  mkdirSync(join(dir, 'scripts'), { recursive: true });
  writeFileSync(join(dir, 'scripts', 'build-plan.js'), body);
}

const PLAN_BUILDER = `
const args = process.argv.slice(2);
const get = (k) => { const i = args.indexOf(k); return i >= 0 ? args[i + 1] : undefined; };
console.error('WARN skip: session baseline-from-antitrainer.json: missing string date');
console.log(JSON.stringify({
  workout_id: get('--workout-id'),
  day_name: 'Ноги А',
  week: 3,
  week_label: 'тяжёлая',
  exercises: [{ slug: 'zhim-nogami', name_ru: 'Жим ногами', target_sets: 4, target_reps: '8-10',
    reps_in_reserve: get('--health') === 'yellow' ? 1 : 0, rest_seconds: 180, weight_kg_target: 255 }],
  _args: args,
  _cwd: process.cwd(),
}, null, 2));
`;

describe('readinessFor — what Greg said about this date', () => {
  it('no signal file: train as planned', () => {
    expect(readinessFor('2026-10-02', join(dir, 'absent.json'))).toEqual({ kind: 'ok', health: null });
  });

  it('a signal about another day is not today\'s signal (Greg skips green days)', () => {
    const p = writeSignal({ date: '2026-10-01', level: 'yellow', readiness: 45 });
    expect(readinessFor('2026-10-02', p)).toEqual({ kind: 'ok', health: null });
  });

  it('yellow today lowers the load', () => {
    const p = writeSignal({ date: '2026-10-02', level: 'yellow', readiness: 61 });
    expect(readinessFor('2026-10-02', p)).toEqual({ kind: 'ok', health: 'yellow' });
  });

  it('green with readiness under 70 is still yellow for the plan (the builder\'s band)', () => {
    const p = writeSignal({ date: '2026-10-02', level: 'green', readiness: 66 });
    expect(readinessFor('2026-10-02', p)).toEqual({ kind: 'ok', health: 'yellow' });
  });

  it('green with readiness 70+ trains as planned', () => {
    const p = writeSignal({ date: '2026-10-02', level: 'green', readiness: 74 });
    expect(readinessFor('2026-10-02', p)).toEqual({ kind: 'ok', health: null });
  });

  it('red today means rest — no plan', () => {
    const p = writeSignal({ date: '2026-10-02', level: 'red', readiness: 38 });
    expect(readinessFor('2026-10-02', p)).toEqual({ kind: 'rest' });
  });

  it('an unreadable file is unknown, never silently green', () => {
    const p = writeSignal('{not json');
    expect(readinessFor('2026-10-02', p).kind).toBe('unknown');
  });

  it('a level outside green/yellow/red is unknown', () => {
    const p = writeSignal({ date: '2026-10-02', level: 'orange' });
    expect(readinessFor('2026-10-02', p).kind).toBe('unknown');
  });
});

describe('buildPlan — runs the agent\'s own builder', () => {
  it('returns the plan the script printed, run from the agent dir with the workout id', () => {
    writeBuilder(PLAN_BUILDER);
    const r = buildPlan('2026-10-02', null, dir);
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(r.plan.day_name).toBe('Ноги А');
    expect(r.plan._args).toEqual(['--workout-id', '2026-10-02']);
    expect(r.plan._cwd).toBe(dir);
  });

  it('passes the health flag through', () => {
    writeBuilder(PLAN_BUILDER);
    const r = buildPlan('2026-10-02', 'yellow', dir);
    expect(r.ok && r.plan._args).toEqual(['--workout-id', '2026-10-02', '--health', 'yellow']);
  });

  it('passes an explicit split day through', () => {
    writeBuilder(PLAN_BUILDER);
    const r = buildPlan('2026-10-02', null, dir, { day: 'upper_a' });
    expect(r.ok && r.plan._args).toEqual(['--workout-id', '2026-10-02', '--day', 'upper_a']);
  });

  it('a closed mesocycle is not a plan', () => {
    writeBuilder(`console.log(JSON.stringify({ cycle_complete: true, sessions_done: 15, sessions_planned: 16 }))`);
    const r = buildPlan('2026-10-02', null, dir);
    expect(r).toMatchObject({ ok: false, reason: 'cycle_complete' });
  });

  it('a crashing builder fails with its stderr', () => {
    writeBuilder(`console.error('build-plan: no day key'); process.exit(1);`);
    const r = buildPlan('2026-10-02', null, dir);
    expect(r).toMatchObject({ ok: false, reason: 'failed' });
    expect(!r.ok && r.detail).toContain('no day key');
  });

  it('output that is not a plan fails', () => {
    writeBuilder(`console.log('hello')`);
    expect(buildPlan('2026-10-02', null, dir)).toMatchObject({ ok: false, reason: 'failed' });
  });

  it('a missing builder fails instead of throwing', () => {
    expect(buildPlan('2026-10-02', null, dir)).toMatchObject({ ok: false, reason: 'failed' });
  });
});

describe('sendWorkoutPlan — the card and the copy the agent reads later', () => {
  it('writes the workout_plan control row with a manifest from the exercise images', () => {
    const exercisesDir = join(dir, 'exercises');
    mkdirSync(exercisesDir);
    writeFileSync(join(exercisesDir, 'zhim-nogami.gif'), Buffer.from('GIF8'));
    const plan = { day_name: 'Ноги А', week: 3, week_label: 'тяжёлая', exercises: [{ slug: 'zhim-nogami', target_sets: 4 }] };

    const res = sendWorkoutPlan('2026-10-02', plan, { agentDir: dir, exercisesDir });

    expect(res.images).toBe(1);
    const rows = getUndeliveredMessages();
    expect(rows).toHaveLength(1);
    expect(rows[0].kind).toBe('control');
    const body = JSON.parse(rows[0].content);
    expect(body.type).toBe('workout_plan');
    expect(body.payload.workout_id).toBe('2026-10-02');
    expect(body.payload.plan_json.exercises[0].slug).toBe('zhim-nogami');
    expect(body.payload.image_manifest).toHaveLength(1);
  });

  it('keeps the sent plan at plans/<workout_id>.json — the agent never saw a plan the runner sent', () => {
    const plan = { day_name: 'Ноги А', week: 3, week_label: 'тяжёлая', exercises: [{ slug: 'zhim-nogami', target_sets: 4 }] };
    sendWorkoutPlan('2026-10-02', plan, { agentDir: dir, exercisesDir: join(dir, 'exercises') });
    const saved = join(dir, 'plans', '2026-10-02.json');
    expect(existsSync(saved)).toBe(true);
    expect(JSON.parse(readFileSync(saved, 'utf8')).exercises[0].target_sets).toBe(4);
  });

  it('maps program vocab onto the wire vocab, as the tool always did', () => {
    const plan = { day_name: 'Ноги А', week: 3, week_label: 'тяжёлая', exercises: [{ exercise_slug: 'zhim-nogami', target_rir: 0, rest_sec: 180 }] };
    sendWorkoutPlan('2026-10-02', plan, { agentDir: dir, exercisesDir: join(dir, 'exercises') });
    const ex = JSON.parse(getUndeliveredMessages()[0].content).payload.plan_json.exercises[0];
    expect(ex).toMatchObject({ slug: 'zhim-nogami', reps_in_reserve: 0, rest_seconds: 180 });
  });

  it('trusts a supplied manifest untouched', () => {
    const plan = { day_name: 'Ноги А', week: 3, week_label: 'тяжёлая', exercises: [] };
    sendWorkoutPlan('w1', plan, { agentDir: dir, exercisesDir: join(dir, 'exercises'), manifest: [{ slug: 'squat', sha256: 'abc' }] });
    expect(JSON.parse(getUndeliveredMessages()[0].content).payload.image_manifest).toEqual([{ slug: 'squat', sha256: 'abc' }]);
  });
});
