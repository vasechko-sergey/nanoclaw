/**
 * Async deferred `request_context` MCP tool.
 *
 * The agent calls this to pull live device context (location, health,
 * calendar, etc.) from the user's iOS device. The handler:
 *
 *   1. Writes a `context_request` envelope to messages_out with a fresh
 *      `request_id` and an `expires_at_ms` deadline derived from
 *      `timeout_ms` (default 10s).
 *   2. Returns a Promise that resolves when the host calls
 *      `onContextResponse` for that `request_id`, or rejects on timeout.
 *
 * Late `context_response` envelopes (after the timeout fired) are
 * silently dropped — the entry has already been removed from `pending`.
 *
 * `onContextResponse` is exported so the inbound dispatcher (Task 3.3)
 * can route `context_response` rows from messages_in back into the
 * pending promise. There is no DB persistence: a container restart loses
 * any in-flight request — the agent will see a timeout rejection.
 *
 * `registerRequestContextTool()` adapts this zod-shaped tool into the
 * registry's JSON-Schema `McpToolDefinition` and is invoked from the
 * MCP tools barrel only when the session is wired to the ios-app
 * channel — non-iOS sessions never see this tool.
 */
import type { ContextField } from '@shared/ios-app-protocol/index.js';
import { z } from 'zod';

import { writeMessageOut as writeMessageOutRaw } from '../db/messages-out.js';
import { registerTools } from './server.js';
import type { McpToolDefinition } from './types.js';

// Re-declare the enum locally rather than reusing the shared zod value.
// The shared package compiles against a sibling zod copy with a different
// `_zod.version.minor`, which zod's branded type system rejects when
// composing across the boundary. The string list is the source of truth in
// `shared/ios-app-protocol/v2.ts`; this list must stay in sync, and the
// `satisfies` check below makes a drift a compile error.
const CONTEXT_FIELDS = [
  'health', 'calendar', 'device', 'next_event', 'recent_locations', 'screen_state', 'reminders', 'focus', 'motion',
] as const satisfies readonly ContextField[];

// Bidirectional check: if shared adds a new ContextField, this assignment
// fails to compile because the literal union won't cover it.
const _exhaustive: (typeof CONTEXT_FIELDS)[number] extends ContextField
  ? ContextField extends (typeof CONTEXT_FIELDS)[number]
    ? true
    : false
  : false = true;
void _exhaustive;

const InputSchema = z.object({
  fields: z.array(z.enum(CONTEXT_FIELDS)).min(1),
  params: z.object({
    health_days: z.number().int().min(1).max(30).optional(),
    calendar_window: z.enum(['today', 'next_7d', 'next_30d']).optional(),
    locations_hours: z.number().int().min(1).max(168).optional(),
  }).optional(),
  timeout_ms: z.number().int().min(1000).max(30000).optional(),
});

interface Entry {
  resolve: (v: unknown) => void;
  reject: (e: Error) => void;
  timer: ReturnType<typeof setTimeout>;
}

const pending = new Map<string, Entry>();

export interface ToolContext {
  session_id: string;
  writeMessageOut: (
    session_id: string,
    msg: { type: string; payload: Record<string, unknown> },
  ) => Promise<void>;
}

export const requestContextTool = {
  name: 'request_context',
  description:
    'Pull device context (location, health, calendar, etc.) from the user iOS device. Async — blocks until device replies or timeout.',
  inputSchema: InputSchema,
  handler: (input: z.infer<typeof InputSchema>, ctx: ToolContext): Promise<unknown> => {
    const request_id = crypto.randomUUID();
    const timeout_ms = input.timeout_ms ?? 10000;
    const expires_at_ms = Date.now() + timeout_ms;
    // Fire writeMessageOut synchronously (don't await) and register the
    // pending entry in the same tick so onContextResponse can resolve us
    // without waiting on the writeMessageOut microtask first. Errors from
    // writeMessageOut surface via reject.
    const write = ctx.writeMessageOut(ctx.session_id, {
      type: 'context_request',
      payload: {
        request_id,
        fields: input.fields,
        params: input.params ?? {},
        expires_at_ms,
      },
    });
    const result = new Promise<unknown>((resolve, reject) => {
      const timer = setTimeout(() => {
        pending.delete(request_id);
        reject(new Error('[device offline / timeout]'));
      }, timeout_ms);
      pending.set(request_id, { resolve, reject, timer });
    });
    write.catch((err) => {
      const entry = pending.get(request_id);
      if (!entry) return;
      clearTimeout(entry.timer);
      pending.delete(request_id);
      entry.reject(err instanceof Error ? err : new Error(String(err)));
    });
    // Attach a no-op handler to suppress "unhandled rejection" warnings if
    // the caller awaits something else first (e.g. a sleep) before awaiting
    // this promise. The original `result` still rejects for the consumer.
    result.catch(() => {});
    return result;
  },
};

export function onContextResponse(envelope: {
  request_id: string;
  data?: Record<string, unknown>;
  errors?: Record<string, string>;
}): void {
  const entry = pending.get(envelope.request_id);
  if (!entry) return;
  clearTimeout(entry.timer);
  pending.delete(envelope.request_id);
  const data = envelope.data ?? {};
  const errors = envelope.errors ?? {};
  if (Object.keys(errors).length > 0 && Object.keys(data).length === 0) {
    entry.reject(new Error(`[context error: ${JSON.stringify(errors)}]`));
  } else {
    entry.resolve({ data, errors });
  }
}

/**
 * Build the MCP registry adapter wrapping `requestContextTool`.
 *
 * Two impedance mismatches handled here:
 *
 *  1. The registry expects `inputSchema` as a JSON Schema; the tool was
 *     authored against a zod schema. `z.toJSONSchema` lifts it across.
 *     The schema is materialized once at registration time; per-call
 *     parsing still uses the original zod schema.
 *
 *  2. The registry hands `handler(args)` raw record args; the tool was
 *     authored against `(input, ctx)` with a ToolContext-style
 *     `writeMessageOut(session_id, msg)`. The shim closes over the
 *     session id and re-shapes the call into the real
 *     `writeMessageOut({ id, kind, content })` signature, routing the
 *     envelope as `kind='control'` on the session's ios-app channel.
 */
export function buildRequestContextDefinition(opts: {
  session_id: string;
  channel_type: string;
  platform_id: string | null;
}): McpToolDefinition {
  const jsonSchema = z.toJSONSchema(InputSchema) as Record<string, unknown>;
  return {
    tool: {
      name: requestContextTool.name,
      description: requestContextTool.description,
      // Cast: zod's JSON Schema output is structurally compatible with the
      // MCP `Tool.inputSchema` type but typed as a generic record.
      inputSchema: jsonSchema as { type: 'object' } & Record<string, unknown>,
    },
    async handler(args) {
      const parsed = InputSchema.safeParse(args);
      if (!parsed.success) {
        return {
          content: [
            {
              type: 'text' as const,
              text: `Error: invalid request_context input — ${parsed.error.message}`,
            },
          ],
          isError: true,
        };
      }
      try {
        const ctx: ToolContext = {
          session_id: opts.session_id,
          // The tool was authored against an abstract `writeMessageOut`
          // that takes a session_id + {type, payload} envelope. The real
          // writer is row-oriented; serialize the envelope into the row's
          // `content` JSON so the host can decode it back to a control
          // envelope on the wire.
          writeMessageOut: async (_session_id, msg) => {
            writeMessageOutRaw({
              id: `req-${msg.payload.request_id ?? Date.now()}`,
              kind: 'control',
              channel_type: opts.channel_type,
              platform_id: opts.platform_id,
              thread_id: null,
              content: JSON.stringify({ type: msg.type, ...msg.payload }),
            });
          },
        };
        const result = await requestContextTool.handler(parsed.data, ctx);
        return {
          content: [{ type: 'text' as const, text: JSON.stringify(result) }],
        };
      } catch (err) {
        return {
          content: [
            {
              type: 'text' as const,
              text: `Error: ${err instanceof Error ? err.message : String(err)}`,
            },
          ],
          isError: true,
        };
      }
    },
  };
}

/**
 * True when a session's channel_type is any iOS transport — both the legacy
 * `ios-app` (v1, removed) and the current `ios-app-v2`. The `request_context`
 * tool is gated on this.
 *
 * Bug history: this gate used to be `channel_type === 'ios-app'`, which
 * silently excluded every v2 session (`ios-app-v2`) and killed health/context
 * pull for Greg, Gordon, and any other iOS agent. `startsWith` matches both
 * and is future-proof for any later `ios-app-*` transport. Returns a type
 * predicate so callers narrow `string | null → string` past the guard.
 */
export function isIosChannel(channel_type: string | null): channel_type is string {
  return channel_type?.startsWith('ios-app') ?? false;
}

/**
 * Register `request_context` for the current session, ONLY when the
 * session is bound to the ios-app channel. No-op otherwise. Called from
 * the MCP tools barrel after session routing has been established.
 *
 * Channel guard at registration time rather than handler time keeps the
 * tool off the ListTools response for non-iOS agents — the agent never
 * even learns the tool exists.
 */
export function registerRequestContextTool(opts: {
  session_id: string;
  channel_type: string | null;
  platform_id: string | null;
}): void {
  if (!isIosChannel(opts.channel_type)) return;
  registerTools([
    buildRequestContextDefinition({
      session_id: opts.session_id,
      channel_type: opts.channel_type,
      platform_id: opts.platform_id,
    }),
  ]);
}
