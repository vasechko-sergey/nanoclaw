import { describe, it, expect, beforeEach } from 'vitest';
import { openTransportDb, type TransportDb } from './transport-db.js';
import { ReceiptStore } from './receipt-store.js';

let db: TransportDb;
let store: ReceiptStore;

beforeEach(() => {
  db = openTransportDb(':memory:');
  store = new ReceiptStore(db);
});

describe('ReceiptStore', () => {
  it('creates receipts table on construction', () => {
    const tables = (
      db.raw.prepare(`SELECT name FROM sqlite_master WHERE type='table'`).all() as { name: string }[]
    ).map((r) => r.name);
    expect(tables).toContain('receipts');
  });

  it('records delivered + read receipts idempotently', () => {
    store.record('ios-app:dev-1', ['m1', 'm2'], 'delivered');
    store.record('ios-app:dev-1', ['m1'], 'read');
    store.record('ios-app:dev-1', ['m1'], 'delivered'); // duplicate ignored
    const rows = db.raw.prepare(`SELECT message_id, state FROM receipts ORDER BY message_id, state`).all();
    expect(rows).toEqual([
      { message_id: 'm1', state: 'delivered' },
      { message_id: 'm1', state: 'read' },
      { message_id: 'm2', state: 'delivered' },
    ]);
  });
});
