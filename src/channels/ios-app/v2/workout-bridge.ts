import { randomUUID } from 'node:crypto';
import type { AnyEnvelope } from '../../../../shared/ios-app-protocol/index.js';

export interface WorkoutBridgeDeps {
  /**
   * Write a JSON-encoded system inbound row into the agent's session DB.
   * `trigger` follows the messages_in convention: 1 = wake the agent, 0 =
   * accumulate as silent context (rides along to the next waking turn).
   */
  writeInboundSystemMessage: (input: { session_id: string; text: string; tag: string; trigger: 0 | 1 }) => void;
  /** Reverse: session → device that should receive an outbound envelope. */
  resolvePlatformForSession: (session_id: string) => string | null;
  /** Hand the envelope to the WS handler (it allocates seq + flushes if connected). */
  sendEnvelopeToDevice: (platform_id: string, envelope: unknown) => void;
}

/** Workout envelope types routed iOS → Payne (inbound). */
const IOS_TO_AGENT_TYPES: ReadonlySet<string> = new Set([
  'workout_start_request',
  'set_log',
  'exercise_done',
  'workout_complete',
  'workout_abort',
  'exercise_swap_request',
  'exercise_swap_confirm',
  'image_request',
  'intro_request',
]);

/**
 * Per-set telemetry the user generates rapidly during a workout. These
 * accumulate as silent context (trigger=0, don't wake the agent per-set) and
 * ride along to the agent on the next waking event — in practice the
 * `workout_complete`, whose `full_session_json` is the authoritative record.
 * This keeps Payne from spinning up one agent turn per logged set. Every other
 * inbound type (workout_complete/abort, image_request, swap, intro, …) wakes.
 */
const ACCUMULATE_EVENTS: ReadonlySet<string> = new Set(['set_log', 'exercise_done']);

/** Workout envelope types routed Payne → iOS (outbound). */
const AGENT_TO_IOS_TYPES: ReadonlySet<string> = new Set([
  'workout_plan',
  'coach_message',
  'exercise_swap_options',
  'program_update',
  'image_blob',
]);

/**
 * iOS ↔ Payne workout-event bridge. Mirrors ContextBridge: structured WS
 * envelopes get translated to/from session inbound rows so the agent can
 * see them as JSON system messages and emit them via the standard outbound
 * path with a `content.type` discriminator.
 */
export class WorkoutBridge {
  constructor(private deps: WorkoutBridgeDeps) {}

  /** True if this envelope type is an iOS → Payne workout type. */
  handlesInbound(type: string): boolean {
    return IOS_TO_AGENT_TYPES.has(type);
  }

  /** True if this content.type is a Payne → iOS workout outbound. */
  handlesOutbound(contentType: string): boolean {
    return AGENT_TO_IOS_TYPES.has(contentType);
  }

  /** Called by the inbound dispatcher when a workout envelope arrives. */
  handleInbound(session_id: string, env: AnyEnvelope): void {
    if (!this.handlesInbound(env.type)) return;
    const body = JSON.stringify({
      event: env.type,
      payload: (env as { payload?: unknown }).payload ?? {},
    });
    this.deps.writeInboundSystemMessage({
      session_id,
      text: body,
      tag: 'workout',
      trigger: ACCUMULATE_EVENTS.has(env.type) ? 0 : 1,
    });
  }

  /**
   * Called by deliver() when the agent emits content with one of the
   * bridge's outbound types. `content` is the parsed JSON body of the
   * agent's outbound row.
   *
   * Expected shape:
   *   { type: '<workout outbound type>', payload: { ...envelope payload... } }
   */
  handleAgentRequest(input: { session_id: string; content: Record<string, unknown> }): void {
    const type = typeof input.content.type === 'string' ? input.content.type : '';
    if (!this.handlesOutbound(type)) return;
    const platform_id = this.deps.resolvePlatformForSession(input.session_id);
    if (!platform_id) return;

    // All bridge-outbound types are 'control' kind by convention (except
    // image_blob which carries data but kind=control per the protocol
    // schema in shared/ios-app-protocol/v2.ts).
    const envelope = {
      v: 2 as const,
      kind: 'control' as const,
      type,
      id: typeof input.content.id === 'string' ? input.content.id : randomUUID(),
      seq: 0, // ws-handler will allocate
      ts: new Date().toISOString(),
      payload: input.content.payload ?? {},
    };

    this.deps.sendEnvelopeToDevice(platform_id, envelope);
  }
}
