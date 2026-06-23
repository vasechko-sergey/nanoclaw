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

function emitWorkout(h: Harness, payload: unknown = PAYLOAD): void {
  h.workoutBridge.handleAgentRequest({
    session_id: 'sess-1',
    content: { type: 'workout_plan', payload },
  });
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

  // The core design hazard. The host deletes queued rows by a single
  // last_seen_inbound_seq watermark. iOS advances that watermark ONLY for
  // `message` envelopes, never for workout_plan. So if the device ever reports
  // a cursor at/above an UNDELIVERED workout's seq — which happens under
  // multi-device supersession (sim + phone share platform_id `…:default`, one
  // queue, one cursor) — ackUpTo silently drops the workout and the drain never
  // re-sends it. This test documents that loss.
  it('drops an un-delivered workout_plan when the cursor is acked past its seq', async () => {
    h.db.upsertDevice(h.platformId, { capabilities: [] });
    emitWorkout(h); // workout at seq 1 — imagine it was pushed to a now-superseded socket
    // A later chat message lands at seq 2.
    h.handler.sendEnvelopeToDevice(h.platformId, {
      kind: 'data',
      type: 'message',
      payload: { thread_id: 'ios:default', text: 'вот план', agent_id: 'payne' },
    });

    // A device reconnects reporting it has seen up through the chat (seq 2).
    const ws = await h.connectAuthed({ lastSeenInbound: 2 });
    // ackUpTo(2) deleted BOTH rows; nothing is drained.
    await expect(h.expectIncoming(ws, 300)).rejects.toThrow(/timeout/);
    expect(h.queue.list(h.platformId)).toHaveLength(0);
  });
});
