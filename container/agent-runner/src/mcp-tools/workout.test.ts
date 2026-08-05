/**
 * Tests for Payne's workout MCP tools.
 *
 * Uses a real in-memory session DB (initTestSessionDb) and inspects the rows
 * the handlers actually write via writeMessageOut. We deliberately do NOT
 * `mock.module('../db/messages-out.js', ...)` here: bun's module mocks are
 * process-global and persist for the whole `bun test` run with no auto-restore,
 * so a partial stub of messages-out.js leaks into later files (e.g.
 * db/messages-out.test.ts saw the stubbed writeMessageOut and its dispatch
 * counter never moved). A real DB keeps these tests hermetic.
 */
import { describe, it, expect, beforeEach } from 'bun:test';
import { initTestSessionDb, getInboundDb } from '../db/connection.js';
import { getUndeliveredMessages } from '../db/messages-out.js';
import { workoutStartPlan, workoutCoach, workoutSwap } from './workout.js';

/** Seed the per-session reply routing the host writes on every wake. */
function seedRouting(channel = 'ios-app-v2', platform = 'ios-app-v2:default', thread = 'ios:default'): void {
  const db = getInboundDb();
  db.run(
    `CREATE TABLE IF NOT EXISTS session_routing (id INTEGER PRIMARY KEY, channel_type TEXT, platform_id TEXT, thread_id TEXT)`,
  );
  db.run(
    `INSERT OR REPLACE INTO session_routing (id, channel_type, platform_id, thread_id) VALUES (1, '${channel}', '${platform}', '${thread}')`,
  );
}

describe('workout MCP tools', () => {
  beforeEach(() => {
    initTestSessionDb();
    process.env.AGENT_GROUP_ID = 'payne';
  });

  it('workout.start_plan writes a workout_plan outbound row', async () => {
    const res = await workoutStartPlan.handler({
      workout_id: 'w1',
      plan_json: { exercises: [] },
      image_manifest: [{ slug: 'squat', sha256: 'abc' }],
    });
    expect(res.isError).toBeUndefined();
    const rows = getUndeliveredMessages();
    expect(rows).toHaveLength(1);
    expect(rows[0].kind).toBe('control');
    const body = JSON.parse(rows[0].content);
    expect(body.type).toBe('workout_plan');
    expect(body.payload.workout_id).toBe('w1');
    expect(body.payload.plan_json).toEqual({ exercises: [] });
    expect(body.payload.image_manifest).toEqual([{ slug: 'squat', sha256: 'abc' }]);
  });

  it('stamps the session channel routing so the host can deliver the plan', async () => {
    // The on-device bug: the control row went out with NULL platform_id/
    // channel_type, so the host delivery poller dropped it ("Message missing
    // routing fields") before the ios-app workout-bridge ever ran — the plan
    // never left the host and no card ever rendered. The row must carry the
    // session's routing, exactly like a normal reply.
    seedRouting();
    await workoutStartPlan.handler({ workout_id: 'w1', plan_json: { exercises: [] }, image_manifest: [] });
    const row = getUndeliveredMessages().at(-1)!;
    expect(row.channel_type).toBe('ios-app-v2');
    expect(row.platform_id).toBe('ios-app-v2:default');
    expect(row.thread_id).toBe('ios:default');
  });

  it('workout.start_plan defaults image_manifest to [] when omitted (images optional)', async () => {
    const res = await workoutStartPlan.handler({
      workout_id: 'w-noimg',
      plan_json: { exercises: [] },
      // image_manifest intentionally omitted
    });
    expect(res.isError).toBeUndefined();
    const rows = getUndeliveredMessages();
    expect(rows).toHaveLength(1);
    const body = JSON.parse(rows[0].content);
    expect(body.type).toBe('workout_plan');
    expect(body.payload.image_manifest).toEqual([]);
  });

  // The wire contract (shared/ios-app-protocol/v2.ts PlanExerciseSchema) pins the
  // per-exercise vocab to slug / name_ru / reps_in_reserve / rest_seconds /
  // duration_seconds / weight_kg_target. Payne builds plan_json from its INTERNAL
  // program vocab (exercise_slug / name / target_rir / rest_sec /
  // execution_duration_seconds / weight_kg) and the handler used to pass it
  // through verbatim, so iOS decoded N exercises but every remapped field fell to
  // its default — empty slug (identical "" ids collapse the ForEach), blank name,
  // no weight, no rest. The card said "8 упражнений" and rendered nothing. The
  // handler must NORMALIZE each exercise onto the canonical wire vocab.
  it('workout.start_plan normalizes program-vocab exercises onto the canonical wire vocab', async () => {
    await workoutStartPlan.handler({
      workout_id: '2026-08-05',
      plan_json: {
        day_name: 'Верх А',
        week: 3,
        week_label: 'тяжёлая',
        exercises: [
          { exercise_slug: 'hodba', name: 'Ходьба', sets: [], execution_duration_seconds: 300, rest_sec: 0, notes: 'разминка' },
          { exercise_slug: 'zhim', name: 'Жим', target_sets: 5, target_reps: '8-10', target_rir: 0, weight_kg: 70, rest_sec: 180 },
        ],
      },
      image_manifest: [],
    });
    const body = JSON.parse(getUndeliveredMessages().at(-1)!.content);
    // Plan-level keys pass through untouched (they already match the wire).
    expect(body.payload.plan_json.day_name).toBe('Верх А');
    expect(body.payload.plan_json.week).toBe(3);
    expect(body.payload.plan_json.week_label).toBe('тяжёлая');
    // Warmup: null sets, timed, no weight. `sets` array is dropped (not wire).
    expect(body.payload.plan_json.exercises[0]).toEqual({
      slug: 'hodba', name_ru: 'Ходьба', target_sets: null, target_reps: '',
      reps_in_reserve: null, rest_seconds: 0, duration_seconds: 300, notes: 'разминка',
    });
    // Working set: target_rir 0 must survive (nullish map, not truthy).
    expect(body.payload.plan_json.exercises[1]).toEqual({
      slug: 'zhim', name_ru: 'Жим', target_sets: 5, target_reps: '8-10',
      reps_in_reserve: 0, rest_seconds: 180, weight_kg_target: 70,
    });
    // The internal-vocab keys must be GONE — their presence is what broke decode.
    const ex1 = body.payload.plan_json.exercises[1];
    expect(ex1.exercise_slug).toBeUndefined();
    expect(ex1.target_rir).toBeUndefined();
    expect(ex1.rest_sec).toBeUndefined();
    expect(ex1.weight_kg).toBeUndefined();
    expect(ex1.name).toBeUndefined();
  });

  // An already-canonical plan (Payne emitting the documented plan_json vocab, as
  // the historical seq-389 envelope did) must pass through unchanged — the
  // normalizer is idempotent, never a second remap that corrupts correct plans.
  it('workout.start_plan leaves an already-canonical exercise unchanged', async () => {
    await workoutStartPlan.handler({
      workout_id: 'w1',
      plan_json: {
        day_name: 'X', week: 2, week_label: 'Средняя',
        exercises: [
          { slug: 'incline', name_ru: 'Наклонный', target_sets: 4, target_reps: '5-6', reps_in_reserve: 2, rest_seconds: 180, weight_kg_target: 66.25 },
        ],
      },
      image_manifest: [],
    });
    const body = JSON.parse(getUndeliveredMessages().at(-1)!.content);
    expect(body.payload.plan_json.exercises[0]).toEqual({
      slug: 'incline', name_ru: 'Наклонный', target_sets: 4, target_reps: '5-6',
      reps_in_reserve: 2, rest_seconds: 180, weight_kg_target: 66.25,
    });
  });

  it('workout.coach writes a coach_message row', async () => {
    const res = await workoutCoach.handler({ workout_id: 'w1', text: 'good set' });
    expect(res.isError).toBeUndefined();
    const rows = getUndeliveredMessages();
    expect(rows).toHaveLength(1);
    expect(rows[0].kind).toBe('control');
    const body = JSON.parse(rows[0].content);
    expect(body.type).toBe('coach_message');
    expect(body.payload).toEqual({ workout_id: 'w1', text: 'good set' });
  });

  // Fix K: strict set_ref validation. The iOS Codable SetRef requires
  // both fields; a partial ref would fail the WHOLE envelope decode and
  // silently drop the coach text.
  it('workout.coach with a complete set_ref forwards it', async () => {
    await workoutCoach.handler({
      workout_id: 'w1',
      text: 'посмотри технику',
      set_ref: { exercise_slug: 'squat', set_idx: 2 },
    });
    const body = JSON.parse(getUndeliveredMessages()[0].content);
    expect(body.payload.set_ref).toEqual({ exercise_slug: 'squat', set_idx: 2 });
  });

  it('workout.coach drops set_ref when set_idx is missing (preserves text)', async () => {
    const res = await workoutCoach.handler({
      workout_id: 'w1',
      text: 'нормально сделал',
      // set_idx omitted — iOS Codable would throw and drop the whole envelope
      set_ref: { exercise_slug: 'squat' } as unknown as { exercise_slug: string; set_idx: number },
    });
    expect(res.isError).toBeUndefined();
    const body = JSON.parse(getUndeliveredMessages()[0].content);
    expect(body.payload.text).toBe('нормально сделал');
    expect(body.payload.set_ref).toBeUndefined();
  });

  it('workout.coach drops set_ref when exercise_slug is missing', async () => {
    await workoutCoach.handler({
      workout_id: 'w1',
      text: 'ok',
      set_ref: { set_idx: 0 } as unknown as { exercise_slug: string; set_idx: number },
    });
    const body = JSON.parse(getUndeliveredMessages()[0].content);
    expect(body.payload.set_ref).toBeUndefined();
  });

  it('workout.coach drops set_ref when exercise_slug is empty string', async () => {
    await workoutCoach.handler({
      workout_id: 'w1',
      text: 'ok',
      set_ref: { exercise_slug: '', set_idx: 0 },
    });
    const body = JSON.parse(getUndeliveredMessages()[0].content);
    expect(body.payload.set_ref).toBeUndefined();
  });

  it('workout.coach drops set_ref when set_idx is negative', async () => {
    await workoutCoach.handler({
      workout_id: 'w1',
      text: 'ok',
      set_ref: { exercise_slug: 'squat', set_idx: -1 },
    });
    const body = JSON.parse(getUndeliveredMessages()[0].content);
    expect(body.payload.set_ref).toBeUndefined();
  });

  it('workout.coach drops set_ref when set_idx is a float', async () => {
    await workoutCoach.handler({
      workout_id: 'w1',
      text: 'ok',
      set_ref: { exercise_slug: 'squat', set_idx: 1.5 },
    });
    const body = JSON.parse(getUndeliveredMessages()[0].content);
    expect(body.payload.set_ref).toBeUndefined();
  });

  // The wire contract (shared/ios-app-protocol/v2.ts ExerciseSwapOptions) and
  // the iOS Codable (V2.ExerciseSwapOptions) require `original_slug` +
  // `alternatives: [{slug, why}]`. The handler used to pass the tool's INPUT
  // field names through verbatim (`from_exercise_slug`, `options: [{slug,
  // reason}]`), so iOS's decode of the required `original_slug`/`alternatives`
  // fields threw and the whole envelope was dropped — the swap sheet spun
  // forever and "замена упражнений" never worked. The handler must MAP the
  // ergonomic input onto the canonical wire shape.
  it('workout.swap emits the canonical wire shape (original_slug + alternatives[{slug,why}])', async () => {
    const res = await workoutSwap.handler({
      workout_id: 'w1',
      from_exercise_slug: 'squat',
      options: [
        { slug: 'leg_press', reason: 'knee' },
        { slug: 'hack_squat', reason: 'quad focus' },
      ],
    });
    expect(res.isError).toBeUndefined();
    const rows = getUndeliveredMessages();
    expect(rows).toHaveLength(1);
    expect(rows[0].kind).toBe('control');
    const body = JSON.parse(rows[0].content);
    expect(body.type).toBe('exercise_swap_options');
    expect(body.payload.workout_id).toBe('w1');
    expect(body.payload.original_slug).toBe('squat');
    expect(body.payload.alternatives).toEqual([
      { slug: 'leg_press', why: 'knee' },
      { slug: 'hack_squat', why: 'quad focus' },
    ]);
    // The pre-fix field names must be gone — their presence is what broke decode.
    expect(body.payload.from_exercise_slug).toBeUndefined();
    expect(body.payload.options).toBeUndefined();
  });

  it('refuses when AGENT_GROUP_ID is not payne', async () => {
    process.env.AGENT_GROUP_ID = 'jarvis';
    const res = await workoutCoach.handler({ workout_id: 'w1', text: 'x' });
    expect(res.isError).toBe(true);
    expect(getUndeliveredMessages()).toHaveLength(0);
  });
});
