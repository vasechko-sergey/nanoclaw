import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { startTestServer, type Harness } from './testing/harness.js';

// Regression for the image_blob head-of-line-blocking incident (2026-06-27):
// multi-MB base64 image envelopes drained ahead of a text reply choked the iOS
// client (main-thread decode + memory spike) so it disconnected before reaching
// the text — the agent reply (greg seq 707) was stranded behind 5 blobs (~5 MB).
//
// The fix keeps bytes OFF the realtime stream: for capability-`image_ref`
// devices the host caches the bytes and enqueues a tiny `image_ready` ref, so a
// text message can never sit behind a multi-MB frame.
const MSG = '99999999-9999-4999-8999-999999999999';
const ONE_MB_B64 = Buffer.alloc(1_000_000, 7).toString('base64'); // ~1.33 MB string

function imageBlob(id: string, slug: string) {
  return {
    kind: 'control',
    type: 'image_blob',
    id,
    payload: { slug, sha256: `sha-${slug}`, base64: ONE_MB_B64, agent_id: 'payne' },
  };
}

describe('image_blob → image_ready delivery (HOL-blocking fix)', () => {
  let h: Harness;
  beforeEach(async () => {
    h = await startTestServer();
  });
  afterEach(async () => {
    await h.close();
  });

  it('ref-capable device: 5 MB of blobs ahead of a text become tiny refs; text deliverable + ackable independently', () => {
    h.db.upsertDevice(h.platformId, { capabilities: ['image_ref'] });

    // Five multi-MB image blobs enqueued AHEAD of the text reply.
    for (let i = 0; i < 5; i++) {
      h.handler.sendEnvelopeToDevice(h.platformId, imageBlob(`blob-${i}`, `ex-${i}`));
    }
    // The agent's text reply, queued behind the blobs.
    h.handler.sendEnvelopeToDevice(h.platformId, {
      kind: 'data',
      type: 'message',
      id: MSG,
      payload: { thread_id: 'thr', text: 'готово, вот ответ' },
    });

    const rows = h.queue.list(h.platformId);
    expect(rows).toHaveLength(6);

    // No multi-MB frame survives on the stream: every queued payload is tiny.
    const totalBytes = rows.reduce((n, r) => n + r.payload_json.length, 0);
    expect(totalBytes).toBeLessThan(10_000); // was ~6.7 MB of base64 before the fix

    // The image rows are refs (no base64), bytes live in the host cache instead.
    const imageRows = rows.filter((r) => r.type === 'image_ready');
    expect(imageRows).toHaveLength(5);
    for (let i = 0; i < 5; i++) {
      expect(h.imageCache.has(`ex-${i}`, `sha-ex-${i}`)).toBe(true);
    }
    expect(rows.some((r) => r.type === 'image_blob')).toBe(false);
    expect(rows.some((r) => r.payload_json.includes('base64'))).toBe(false);

    // The text reply is present and ackable INDEPENDENTLY of the (never-acked)
    // image refs: the message-cursor ack removes only the message; the refs
    // survive (per-id ack model), exactly as before — but now they never block.
    const msgRow = rows.find((r) => r.type === 'message');
    expect(msgRow?.id).toBe(MSG);
    h.queue.ackUpTo(h.platformId, msgRow!.seq);
    const after = h.queue.list(h.platformId);
    expect(after.some((r) => r.type === 'message')).toBe(false);
    expect(after.filter((r) => r.type === 'image_ready')).toHaveLength(5);
  });

  it('non-ref-capable device: blob stays inline (backward-compatible old path)', () => {
    h.db.upsertDevice(h.platformId, { capabilities: [] });
    h.handler.sendEnvelopeToDevice(h.platformId, imageBlob('blob-x', 'ex-x'));

    const rows = h.queue.list(h.platformId);
    expect(rows).toHaveLength(1);
    expect(rows[0].type).toBe('image_blob');
    expect(rows[0].payload_json).toContain('base64');
    expect(h.imageCache.has('ex-x', 'sha-ex-x')).toBe(false);
  });
});
