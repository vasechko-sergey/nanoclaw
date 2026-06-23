import type { TransportDb } from './transport-db.js';
import { MAX_QUEUE_PER_DEVICE, type OutboundQueueRow } from './types.js';

export interface EnqueueInput {
  id: string;
  kind: string;
  type: string;
  payload: unknown;
}

/**
 * The ONLY outbound type the iOS client advances its `last_seen_inbound_seq`
 * cursor for. Everything else (workout-family, context_request, …) is removed
 * from the queue solely by an explicit per-id `delivered` ack (`ackById`). See
 * `ackUpTo` for why the cursor is scoped this tightly.
 */
const CURSOR_ACKED_TYPE = 'message';

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

  /**
   * Cursor-based bulk ack used on reconnect: the device reports the highest
   * inbound seq it has processed and we drop everything at/below it in one shot,
   * so a long backlog the device already saw isn't redelivered.
   *
   * Scoped to `message` ONLY. The cursor is a single watermark, but the iOS
   * client advances it exclusively for chat `message` envelopes — never for
   * workout-family / context_request / … And because envelopes share one seq
   * space, a plain `seq <= ?` delete would strand any non-message envelope the
   * moment a later chat moved the cursor past it (the confirmed workout bug:
   * Payne sends a chat text right after the plan → "текст был, карточки нет").
   *
   * So the cursor only deletes the one type it actually tracks. Every other
   * type is removed solely by a per-id `delivered` ack (`ackById`) — the real
   * delivery guarantee — and survives in the queue, redelivered on each drain,
   * until the device confirms it by id. Device-side dedup makes redelivery a
   * no-op, so this can never lose or double a message.
   */
  ackUpTo(platform_id: string, seq: number): void {
    this.db.raw
      .prepare(`DELETE FROM outbound_queue WHERE platform_id = ? AND seq <= ? AND type = ?`)
      .run(platform_id, seq, CURSOR_ACKED_TYPE);
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
