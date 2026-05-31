// UI-only bookkeeping for delivered/read on agent→user messages.
// Adapter never propagates these to the agent.
import type { TransportDb } from './transport-db.js';

export class ReceiptStore {
  constructor(private db: TransportDb) {
    this.db.raw.exec(`
      CREATE TABLE IF NOT EXISTS receipts (
        platform_id TEXT NOT NULL,
        message_id TEXT NOT NULL,
        state TEXT NOT NULL CHECK (state IN ('delivered','read')),
        ts INTEGER NOT NULL,
        PRIMARY KEY (platform_id, message_id, state)
      );
    `);
  }
  record(platform_id: string, ids: string[], state: 'delivered' | 'read'): void {
    const stmt = this.db.raw.prepare(`
      INSERT OR IGNORE INTO receipts (platform_id, message_id, state, ts) VALUES (?, ?, ?, ?)
    `);
    const now = Date.now();
    this.db.raw.transaction(() => {
      for (const id of ids) stmt.run(platform_id, id, state, now);
    })();
  }
}
