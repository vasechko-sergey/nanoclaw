import type { TransportDb } from './transport-db.js';
import { MAX_QUEUE_PER_DEVICE, type OutboundQueueRow } from './types.js';

export interface EnqueueInput {
  id: string;
  kind: string;
  type: string;
  payload: unknown;
}

/**
 * Outbound envelope types that are removed from the queue ONLY by an explicit
 * per-id `delivered` ack — never by the chat-message cursor (`ackUpTo`). These
 * are the Payne→iOS workout-family control envelopes (mirror of the
 * workout-bridge's AGENT_TO_IOS_TYPES): the iOS client never advances its
 * inbound cursor for them, so cursor-based deletion would strand them.
 */
export const PER_ID_ACK_TYPES = [
  'workout_plan',
  'coach_message',
  'exercise_swap_options',
  'program_update',
  'image_blob',
] as const;

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
   * Cursor-based ack: the device reports the highest CONTIGUOUS inbound seq it
   * has processed and we drop everything at/below it. But iOS only advances that
   * cursor for chat `message` envelopes — never for workout-family control
   * envelopes — and Payne always sends a chat text right after a workout_plan.
   * So a plain `seq <= ?` delete strands the plan: the following text moves the
   * cursor past it and it is dropped before delivery ("текст был, карточки нет").
   *
   * Workout-family rows are therefore EXEMPT from cursor deletion. They are
   * removed only by an explicit per-id `delivered` ack (`ackById`), so they
   * survive in the queue and are redelivered on every drain until the device
   * confirms receipt.
   */
  ackUpTo(platform_id: string, seq: number): void {
    this.db.raw
      .prepare(
        `DELETE FROM outbound_queue
         WHERE platform_id = ? AND seq <= ?
           AND type NOT IN (${PER_ID_ACK_TYPES.map(() => '?').join(', ')})`,
      )
      .run(platform_id, seq, ...PER_ID_ACK_TYPES);
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
