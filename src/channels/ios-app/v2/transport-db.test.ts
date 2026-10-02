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

  it('last_seen_outbound_seq follows the latest seq, including a restarted app counter', () => {
    db.upsertDevice('ios-app:dev-1', {});
    db.setLastSeenOutbound('ios-app:dev-1', 698);
    // App reinstalled: its send counter starts over. A cursor stuck at 698
    // would tell the app "I have everything up to 698" on every reconnect.
    db.setLastSeenOutbound('ios-app:dev-1', 1);
    expect(db.getDevice('ios-app:dev-1')!.last_seen_outbound_seq).toBe(1);
  });

  it('allocates monotonic emitted seqs', () => {
    db.upsertDevice('ios-app:dev-1', {});
    expect(db.allocateInboundSeq('ios-app:dev-1')).toBe(1);
    expect(db.allocateInboundSeq('ios-app:dev-1')).toBe(2);
    expect(db.allocateInboundSeq('ios-app:dev-1')).toBe(3);
  });
});
