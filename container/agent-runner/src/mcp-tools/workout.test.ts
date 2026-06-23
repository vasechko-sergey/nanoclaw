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
import { initTestSessionDb } from '../db/connection.js';
import { getUndeliveredMessages } from '../db/messages-out.js';
import { workoutStartPlan, workoutCoach, workoutSwap } from './workout.js';

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
