import { describe, it, expect, beforeEach } from 'vitest';
import { openTransportDb, type TransportDb } from './transport-db.js';

let db: TransportDb;
beforeEach(() => {
  db = openTransportDb(':memory:');
});

describe('transport-db', () => {
  it('creates tables on open', () => {
    const names = (db.raw.prepare(`SELECT name FROM sqlite_master WHERE type='table'`).all() as { name: string }[])
      .map((r) => r.name)
      .sort();
    expect(names).toEqual(
      expect.arrayContaining(['devices', 'outbound_queue', 'inbound_dedup', 'pending_context_requests']),
    );
  });

  it('upserts a device row', () => {
    db.upsertDevice('ios-app:dev-1', { capabilities: ['location'] });
    const row = db.getDevice('ios-app:dev-1');
    expect(row?.last_seen_outbound_seq).toBe(0);
    expect(row?.last_emitted_inbound_seq).toBe(0);
    expect(JSON.parse(row!.capabilities_json!)).toEqual(['location']);
  });

  it('advances last_seen_outbound_seq monotonically', () => {
    db.upsertDevice('ios-app:dev-1', {});
    db.advanceLastSeenOutbound('ios-app:dev-1', 5);
    db.advanceLastSeenOutbound('ios-app:dev-1', 3); // ignored — lower
    db.advanceLastSeenOutbound('ios-app:dev-1', 10);
    expect(db.getDevice('ios-app:dev-1')!.last_seen_outbound_seq).toBe(10);
  });

  it('allocates monotonic emitted seqs', () => {
    db.upsertDevice('ios-app:dev-1', {});
    expect(db.allocateInboundSeq('ios-app:dev-1')).toBe(1);
    expect(db.allocateInboundSeq('ios-app:dev-1')).toBe(2);
    expect(db.allocateInboundSeq('ios-app:dev-1')).toBe(3);
  });
});
