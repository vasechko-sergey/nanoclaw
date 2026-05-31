import type { TransportDb } from './transport-db.js';
import { MAX_QUEUE_PER_DEVICE, type OutboundQueueRow } from './types.js';

export interface EnqueueInput {
  id: string;
  kind: string;
  type: string;
  payload: unknown;
}

export class OutboundQueue {
  constructor(private db: TransportDb) {}

  enqueue(platform_id: string, input: EnqueueInput): number {
    return this.db.raw.transaction(() => {
      const seq = this.db.allocateInboundSeq(platform_id);
      const count = this.db.raw
        .prepare(`SELECT COUNT(*) AS n FROM outbound_queue WHERE platform_id = ?`)
        .get(platform_id) as { n: number };
      if (count.n >= MAX_QUEUE_PER_DEVICE) {
        const toDrop = count.n - MAX_QUEUE_PER_DEVICE + 1;
        this.db.raw
          .prepare(
            `
          DELETE FROM outbound_queue
          WHERE platform_id = ? AND seq IN (
            SELECT seq FROM outbound_queue WHERE platform_id = ? ORDER BY seq ASC LIMIT ?
          )
        `,
          )
          .run(platform_id, platform_id, toDrop);
      }
      this.db.raw
        .prepare(
          `
        INSERT INTO outbound_queue (platform_id, seq, id, kind, type, payload_json, created_at)
        VALUES (?, ?, ?, ?, ?, ?, ?)
      `,
        )
        .run(platform_id, seq, input.id, input.kind, input.type, JSON.stringify(input.payload), Date.now());
      return seq;
    })();
  }

  ackById(platform_id: string, id: string): void {
    this.db.raw.prepare(`DELETE FROM outbound_queue WHERE platform_id = ? AND id = ?`).run(platform_id, id);
  }

  ackUpTo(platform_id: string, seq: number): void {
    this.db.raw.prepare(`DELETE FROM outbound_queue WHERE platform_id = ? AND seq <= ?`).run(platform_id, seq);
  }

  list(platform_id: string): OutboundQueueRow[] {
    return this.db.raw
      .prepare(`SELECT * FROM outbound_queue WHERE platform_id = ? ORDER BY seq ASC`)
      .all(platform_id) as OutboundQueueRow[];
  }

  listOlderThan(platform_id: string, beforeMs: number): OutboundQueueRow[] {
    return this.db.raw
      .prepare(`SELECT * FROM outbound_queue WHERE platform_id = ? AND created_at < ? ORDER BY seq ASC`)
      .all(platform_id, beforeMs) as OutboundQueueRow[];
  }
}
