import { describe, it, expect, beforeEach } from 'vitest';
import { openTransportDb, type TransportDb } from './transport-db.js';
import { OutboundQueue, type EnqueueInput } from './outbound-queue.js';
import { MAX_QUEUE_PER_DEVICE } from './types.js';

let db: TransportDb;
let q: OutboundQueue;
beforeEach(() => {
  db = openTransportDb(':memory:');
  db.upsertDevice('ios-app:dev-1', {});
  q = new OutboundQueue(db);
});

const env = (over: Partial<EnqueueInput> = {}): EnqueueInput => ({
  id: over.id ?? '11111111-1111-4111-8111-111111111111',
  kind: over.kind ?? 'data',
  type: over.type ?? 'message',
  payload: over.payload ?? { thread_id: 't', text: 'hi' },
});

describe('OutboundQueue', () => {
  it('enqueue allocates seq and stores row', () => {
    const seq = q.enqueue('ios-app:dev-1', env());
    expect(seq).toBe(1);
    expect(q.list('ios-app:dev-1')).toHaveLength(1);
  });

  it('ack by id removes the row', () => {
    q.enqueue('ios-app:dev-1', env({ id: '11111111-1111-4111-8111-111111111111' }));
    q.enqueue('ios-app:dev-1', env({ id: '22222222-2222-4222-8222-222222222222' }));
    q.ackById('ios-app:dev-1', '11111111-1111-4111-8111-111111111111');
    const ids = q.list('ios-app:dev-1').map((r) => r.id);
    expect(ids).toEqual(['22222222-2222-4222-8222-222222222222']);
  });

  it('ackUpTo seq removes all rows <= seq', () => {
    for (let i = 0; i < 5; i++) {
      q.enqueue('ios-app:dev-1', env({ id: `1111111${i}-1111-4111-8111-111111111111` }));
    }
    q.ackUpTo('ios-app:dev-1', 3);
    expect(q.list('ios-app:dev-1').map((r) => r.seq)).toEqual([4, 5]);
  });

  it('overflow drops oldest when > MAX_QUEUE_PER_DEVICE', () => {
    for (let i = 0; i < MAX_QUEUE_PER_DEVICE + 5; i++) {
      q.enqueue('ios-app:dev-1', env({ id: `${i.toString(16).padStart(8, '0')}-1111-4111-8111-111111111111` }));
    }
    const rows = q.list('ios-app:dev-1');
    expect(rows).toHaveLength(MAX_QUEUE_PER_DEVICE);
    expect(rows[0].seq).toBe(6); // first 5 dropped
  });

  it('listOlderThan returns retry candidates', async () => {
    q.enqueue('ios-app:dev-1', env());
    const now = Date.now();
    expect(q.listOlderThan('ios-app:dev-1', now - 10_000)).toHaveLength(0); // freshly enqueued, not older
    // Sleep then verify
    await new Promise((r) => setTimeout(r, 10));
    expect(q.listOlderThan('ios-app:dev-1', Date.now() - 5)).toHaveLength(1);
  });
});
