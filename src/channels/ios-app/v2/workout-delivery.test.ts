// Delivery-layer tests for the workout_plan envelope — the gap between
// "workout reaches the OutboundQueue" (workout-outbound.test.ts) and "iOS
// handleIncoming renders a card" (TransportV2WorkoutInboundTests.swift).
//
// On-device the card never appeared and the sim DB held zero workout rows, yet
// every iOS code path is proven correct on the real bytes. So the frame never
// reached/survived for the device. These tests pin the host's delivery
// guarantees for a workout_plan: live push, offline-then-reconnect drain, and
// the single-cursor ackUpTo accounting that workout envelopes never advance.
import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { startTestServer, type Harness } from './testing/harness.js';

// NON-uuid id — in production delivery.ts stamps the envelope id = the outbound
// row id ("msg-…"), so `status:delivered.payload.ids` carry non-uuids. The
// `delivered` ack MUST still parse (regression: requiring .uuid() closed the
// socket → reconnect loop → workout never cleared).
const WK_ID = 'msg-1782212659592-fsqyh8';

const PAYLOAD = {
  workout_id: '2026-06-23',
  plan_json: {
    day_name: 'Верх А',
    week: 2,
    week_label: 'Средняя',
    exercises: [
      { slug: 'bench', name_ru: 'Жим', target_sets: 4, target_reps: '5-6', reps_in_reserve: 2, rest_seconds: 180 },
    ],
  },
  image_manifest: [{ slug: 'bench', sha256: 'abc', url: '' }],
};

function emitWorkout(h: Harness, id?: string, payload: unknown = PAYLOAD): void {
  h.workoutBridge.handleAgentRequest({
    session_id: 'sess-1',
    content: id ? { type: 'workout_plan', id, payload } : { type: 'workout_plan', payload },
  });
}

/** Poll until `cond` holds or the timeout elapses. */
async function waitFor(cond: () => boolean, ms = 1000): Promise<void> {
  const start = Date.now();
  while (!cond()) {
    if (Date.now() - start > ms) throw new Error('waitFor timeout');
    await new Promise((r) => setTimeout(r, 20));
  }
}

describe('workout_plan delivery', () => {
  let h: Harness;
  beforeEach(async () => {
    h = await startTestServer();
  });
  afterEach(async () => {
    await h.close();
  });

  it('pushes a workout_plan to a live-connected device', async () => {
    const ws = await h.connectAuthed();
    emitWorkout(h);
    const env = await h.expectIncoming(ws);
    expect(env.type).toBe('workout_plan');
    expect(env.kind).toBe('control');
    expect(env.payload.workout_id).toBe('2026-06-23');
    expect(env.payload.image_manifest).toHaveLength(1);
  });

  it('drains a workout_plan enqueued while the device was offline', async () => {
    // Device row must exist for allocateInboundSeq; auth normally creates it.
    h.db.upsertDevice(h.platformId, { capabilities: [] });
    emitWorkout(h); // no live socket → enqueued only (seq 1)

    const ws = await h.connectAuthed({ lastSeenInbound: 0 });
    // auth_ok was consumed inside connectAuthed; the drain frame follows.
    const env = await h.expectIncoming(ws);
    expect(env.type).toBe('workout_plan');
    expect(env.seq).toBe(1);
  });

  it('redelivers an un-acked workout_plan across a reconnect (survives ackUpTo)', async () => {
    h.db.upsertDevice(h.platformId, { capabilities: [] });
    emitWorkout(h); // seq 1, enqueued

    // First connect: device has acked nothing (cursor 0) → drain delivers it.
    const ws1 = await h.connectAuthed({ lastSeenInbound: 0 });
    const first = await h.expectIncoming(ws1);
    expect(first.type).toBe('workout_plan');
    ws1.close();

    // Reconnect still reporting cursor 0 (workout envelopes never advanced the
    // iOS cursor) → the workout must STILL be queued and re-drained, not lost.
    const ws2 = await h.connectAuthed({ lastSeenInbound: 0 });
    const again = await h.expectIncoming(ws2);
    expect(again.type).toBe('workout_plan');
    expect(again.seq).toBe(1);
    expect(h.queue.list(h.platformId).some((r) => r.type === 'workout_plan')).toBe(true);
  });

  // The fix for the confirmed root cause. The host deletes queued rows by a
  // single last_seen_inbound_seq watermark, but iOS advances that watermark
  // ONLY for `message` envelopes, never for workout_plan — and Payne always
  // sends a chat text right AFTER the plan. On-device that text was delivered
  // (cursor moved past the plan) while the plan itself wasn't, so ackUpTo
  // deleted the plan with no redelivery ("текст был, карточки нет").
  //
  // Fix: workout-family rows are EXEMPT from cursor-based ackUpTo. They survive
  // until the device confirms receipt by id (status:delivered → ackById). So a
  // later chat's cursor can never strand the plan; it is redelivered until acked.
  it('keeps a workout_plan when the cursor is acked past its seq (the on-device bug)', async () => {
    h.db.upsertDevice(h.platformId, { capabilities: [] });
    emitWorkout(h, WK_ID); // workout at seq 1
    // Payne's follow-up chat text lands at seq 2.
    h.handler.sendEnvelopeToDevice(h.platformId, {
      kind: 'data',
      type: 'message',
      payload: { thread_id: 'ios:default', text: 'Отправил.', agent_id: 'payne' },
    });

    // Device reconnects reporting it saw through the chat (seq 2) but not the plan.
    const ws = await h.connectAuthed({ lastSeenInbound: 2 });
    // ackUpTo(2) removed the chat message but the workout_plan SURVIVES and is
    // drained for (re)delivery.
    const env = await h.expectIncoming(ws);
    expect(env.type).toBe('workout_plan');
    expect(h.queue.list(h.platformId).map((r) => r.type)).toEqual(['workout_plan']);
  });

  it('removes a workout_plan from the queue when the device confirms delivered by id', async () => {
    h.db.upsertDevice(h.platformId, { capabilities: [] });
    emitWorkout(h, WK_ID);
    const ws = await h.connectAuthed({ lastSeenInbound: 0 });
    const env = await h.expectIncoming(ws);
    expect(env.type).toBe('workout_plan');

    // Device confirms receipt by id (status:delivered) — the per-id ack that
    // replaces cursor-based deletion for workout-family envelopes.
    h.send(ws, {
      v: 2,
      kind: 'status',
      type: 'delivered',
      id: '00000000-0000-4000-8000-0000000000d1',
      seq: null,
      ts: new Date().toISOString(),
      payload: { ids: [WK_ID] },
    });
    await waitFor(() => h.queue.list(h.platformId).length === 0);
    expect(h.queue.list(h.platformId)).toHaveLength(0);
  });
});
