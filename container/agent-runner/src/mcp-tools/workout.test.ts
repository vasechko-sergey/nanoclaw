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

  it('workout.swap writes an exercise_swap_options row', async () => {
    const res = await workoutSwap.handler({
      workout_id: 'w1',
      from_exercise_slug: 'squat',
      options: [{ slug: 'leg_press', reason: 'knee' }],
    });
    expect(res.isError).toBeUndefined();
    const rows = getUndeliveredMessages();
    expect(rows).toHaveLength(1);
    expect(rows[0].kind).toBe('control');
    const body = JSON.parse(rows[0].content);
    expect(body.type).toBe('exercise_swap_options');
    expect(body.payload.from_exercise_slug).toBe('squat');
    expect(body.payload.options).toEqual([{ slug: 'leg_press', reason: 'knee' }]);
  });

  it('refuses when AGENT_GROUP_ID is not payne', async () => {
    process.env.AGENT_GROUP_ID = 'jarvis';
    const res = await workoutCoach.handler({ workout_id: 'w1', text: 'x' });
    expect(res.isError).toBe(true);
    expect(getUndeliveredMessages()).toHaveLength(0);
  });
});
