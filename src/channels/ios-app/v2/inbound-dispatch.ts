import type { TransportDb } from './transport-db.js';
import type { OutboundQueue } from './outbound-queue.js';
import type { ReceiptStore } from './receipt-store.js';
import type { AnyEnvelope } from '../../../../shared/ios-app-protocol/index.js';
import type { WorkoutBridge } from './workout-bridge.js';

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
  /**
   * Resolve `(platform_id, agent_id)` → session id. When `agent_id` is
   * provided we look for the per-agent session under the device's
   * messaging_group; when omitted (or no per-agent session exists) we fall
   * back to whichever session the messaging_group has for the default
   * agent. See `resolveSessionForPlatform` in `./index.ts`.
   */
  resolveSessionForPlatform: (platform_id: string, agent_id: string | undefined) => string | null;
  /** Slug used when an inbound envelope omits `agent_id`. */
  defaultAgentSlug: string;
  /**
   * Route a user-message envelope directly to the addressed agent.
   * Called instead of the host's routeInbound for ios-app-v2 — the adapter
   * already knows the target agent from `payload.agent_id` (defaulting to
   * `defaultAgentSlug` when absent).
   */
  routeToAgent: (input: { platform_id: string; agent_group_id: string; envelope: UserMessageEnvelope }) => void;
  onContextResponse: (input: { platform_id: string; envelope: ContextResponseEnvelope }) => void;
  onAction: (input: { platform_id: string; envelope: ActionResponseEnvelope }) => void;
  onNewConversation: (input: { platform_id: string; envelope: NewConversationEnvelope }) => void;
  onFeedback: (input: { platform_id: string; envelope: FeedbackEnvelope }) => void;
  /** Optional bridge for workout-mode envelopes. When provided, types it
   *  claims via handlesInbound short-circuit ahead of the standard handlers. */
  workoutBridge?: WorkoutBridge;
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

      // Payload-bearing envelope types may carry an optional `agent_id` slug so
      // the device can target a specific agent on a fanned-out messaging_group.
      // This covers message/context_response/new_conversation AND the workout
      // envelopes (set_log, workout_start_request, …) which the iOS app stamps
      // with `agent_id: "payne"` — without honoring it here those route to the
      // default agent (jarvis) and Payne's workout-mode never fires. Stateless
      // types already short-circuited above and never reach this branch.
      const inferredAgent = (env.payload as { agent_id?: string } | undefined)?.agent_id ?? this.deps.defaultAgentSlug;
      const session_id = this.deps.resolveSessionForPlatform(platform_id, inferredAgent);

      // Workout bridge claims set_log / exercise_done / etc. — write to the
      // session as a structured system message and stop here so the standard
      // onUserMessage / onAction etc. flow doesn't double-handle.
      if (this.deps.workoutBridge?.handlesInbound(env.type)) {
        if (session_id) {
          this.deps.workoutBridge.handleInbound(session_id, env);
        }
        return { kind: 'ack' as const };
      }

      switch (env.type) {
        case 'message': {
          const targetSlug = (env.payload as { agent_id?: string }).agent_id ?? this.deps.defaultAgentSlug;
          this.deps.routeToAgent({
            platform_id,
            agent_group_id: targetSlug,
            envelope: env,
          });
          break;
        }
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
