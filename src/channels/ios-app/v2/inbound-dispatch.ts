import type { TransportDb } from './transport-db.js';
import type { OutboundQueue } from './outbound-queue.js';
import type { ReceiptStore } from './receipt-store.js';
import type { AnyEnvelope } from '../../../../shared/ios-app-protocol/index.js';

export type DispatchAction = { kind: 'ack' } | { kind: 'pong'; nonce: string } | { kind: 'noop' };

type UserMessageEnvelope = Extract<AnyEnvelope, { type: 'message' }>;
type ContextResponseEnvelope = Extract<AnyEnvelope, { type: 'context_response' }>;
type ActionResponseEnvelope = Extract<AnyEnvelope, { type: 'action_response' }>;
type NewConversationEnvelope = Extract<AnyEnvelope, { type: 'new_conversation' }>;
type FeedbackEnvelope = Extract<AnyEnvelope, { type: 'feedback' }>;

export interface DispatcherDeps {
  db: TransportDb;
  queue: OutboundQueue;
  receipts: ReceiptStore;
  resolveSessionForPlatform: (platform_id: string) => string | null;
  onUserMessage: (input: { platform_id: string; session_id: string; envelope: UserMessageEnvelope }) => void;
  onContextResponse: (input: { platform_id: string; envelope: ContextResponseEnvelope }) => void;
  onAction: (input: { platform_id: string; envelope: ActionResponseEnvelope }) => void;
  onNewConversation: (input: { platform_id: string; envelope: NewConversationEnvelope }) => void;
  onFeedback: (input: { platform_id: string; envelope: FeedbackEnvelope }) => void;
}

export class InboundDispatcher {
  constructor(private deps: DispatcherDeps) {}

  dispatch(platform_id: string, env: AnyEnvelope): DispatchAction {
    // Stateless types short-circuit.
    if (env.type === 'ping') {
      return { kind: 'pong', nonce: env.payload.nonce };
    }
    if (env.type === 'delivered' || env.type === 'read') {
      this.deps.receipts.record(platform_id, env.payload.ids, env.type);
      return { kind: 'noop' };
    }
    if (env.type === 'ack') {
      return { kind: 'noop' }; // handled separately by ws-handler
    }

    // Ordered types: dedup + persist + dispatch in a transaction.
    return this.deps.db.raw.transaction(() => {
      const existing = this.deps.db.raw
        .prepare(`SELECT 1 FROM inbound_dedup WHERE platform_id = ? AND id = ?`)
        .get(platform_id, env.id);
      if (existing) return { kind: 'ack' as const };

      this.deps.db.raw
        .prepare(
          `
        INSERT INTO inbound_dedup (platform_id, id, seq, received_at) VALUES (?, ?, ?, ?)
      `,
        )
        .run(platform_id, env.id, env.seq ?? 0, Date.now());
      if (env.seq != null) this.deps.db.advanceLastSeenOutbound(platform_id, env.seq);

      const session_id = this.deps.resolveSessionForPlatform(platform_id);

      switch (env.type) {
        case 'message':
          if (session_id) this.deps.onUserMessage({ platform_id, session_id, envelope: env });
          break;
        case 'context_response':
          this.deps.onContextResponse({ platform_id, envelope: env });
          break;
        case 'action_response':
          this.deps.onAction({ platform_id, envelope: env });
          break;
        case 'new_conversation':
          this.deps.onNewConversation({ platform_id, envelope: env });
          break;
        case 'feedback':
          this.deps.onFeedback({ platform_id, envelope: env });
          break;
      }
      return { kind: 'ack' as const };
    })();
  }
}
