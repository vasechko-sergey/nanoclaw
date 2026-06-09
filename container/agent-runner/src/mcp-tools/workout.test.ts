/**
 * Tests for Payne's workout MCP tools.
 *
 * Mocks ../db/messages-out.js so we capture what would have been written
 * without standing up a real SQLite session DB.
 */
import { describe, it, expect, beforeEach, mock } from 'bun:test';

const writes: Array<{ kind: string; content: string }> = [];

mock.module('../db/messages-out.js', () => ({
  writeMessageOut: (m: { kind: string; content: string }) => {
    writes.push({ kind: m.kind, content: m.content });
    return 1;
  },
}));

const { workoutStartPlan, workoutCoach, workoutSwap } = await import('./workout.js');

describe('workout MCP tools', () => {
  beforeEach(() => {
    writes.length = 0;
    process.env.AGENT_GROUP_ID = 'payne';
  });

  it('workout.start_plan writes a workout_plan outbound row', async () => {
    const res = await workoutStartPlan.handler({
      workout_id: 'w1',
      plan_json: { exercises: [] },
      image_manifest: [{ slug: 'squat', sha256: 'abc' }],
    });
    expect(res.isError).toBeUndefined();
    expect(writes).toHaveLength(1);
    expect(writes[0].kind).toBe('control');
    const body = JSON.parse(writes[0].content);
    expect(body.type).toBe('workout_plan');
    expect(body.payload.workout_id).toBe('w1');
    expect(body.payload.plan_json).toEqual({ exercises: [] });
    expect(body.payload.image_manifest).toEqual([{ slug: 'squat', sha256: 'abc' }]);
  });

  it('workout.coach writes a coach_message row', async () => {
    const res = await workoutCoach.handler({ workout_id: 'w1', text: 'good set' });
    expect(res.isError).toBeUndefined();
    expect(writes).toHaveLength(1);
    expect(writes[0].kind).toBe('control');
    const body = JSON.parse(writes[0].content);
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
    expect(writes).toHaveLength(1);
    expect(writes[0].kind).toBe('control');
    const body = JSON.parse(writes[0].content);
    expect(body.type).toBe('exercise_swap_options');
    expect(body.payload.from_exercise_slug).toBe('squat');
    expect(body.payload.options).toEqual([{ slug: 'leg_press', reason: 'knee' }]);
  });

  it('refuses when AGENT_GROUP_ID is not payne', async () => {
    process.env.AGENT_GROUP_ID = 'jarvis';
    const res = await workoutCoach.handler({ workout_id: 'w1', text: 'x' });
    expect(res.isError).toBe(true);
    expect(writes).toHaveLength(0);
  });
});
