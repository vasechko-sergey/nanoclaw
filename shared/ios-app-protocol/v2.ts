// Canonical iOS-app wire protocol v2.
// Both host adapter (Node) and agent-runner (Bun) import from here.
// Swift mirror lives in ios/JarvisApp/Sources/JarvisApp/Protocol/V2.swift
// and is pinned via shared/ios-app-protocol/fixtures/*.json contract tests.
import { z } from 'zod';

export const PROTOCOL_VERSION = 2 as const;

export const EnvelopeBase = z.object({
  v: z.literal(2),
  kind: z.enum(['data', 'control', 'ack', 'status']),
  type: z.string(),
  id: z.string().uuid(),
  // Nullable: ack, ping, pong, status:* envelopes carry seq=null and do not
  // advance the per-direction cursor. Ordered types (message, context_request,
  // context_response, new_conversation, action_response, feedback) require an
  // integer >= 0.
  seq: z.number().int().nonnegative().nullable(),
  ts: z.string().datetime(),
});
export type EnvelopeBase = z.infer<typeof EnvelopeBase>;

export const InlineContext = z.object({
  location: z.object({
    lat: z.number(),
    lon: z.number(),
    accuracy: z.number().optional(),
  }).optional(),
  timestamp: z.string().datetime(),
  timezone: z.string(),
  locality: z.string().optional(),
});
export type InlineContext = z.infer<typeof InlineContext>;

export const ContextFieldEnum = z.enum([
  'health', 'calendar', 'device', 'next_event', 'recent_locations', 'screen_state',
]);
export type ContextField = z.infer<typeof ContextFieldEnum>;

export const Envelopes = {
  Auth: EnvelopeBase.extend({
    kind: z.literal('control'),
    type: z.literal('auth'),
    payload: z.object({
      token: z.string(),
      last_seen_inbound_seq: z.number().int().nonnegative(),
      capabilities: z.array(z.string()),
    }),
  }),
  AuthOk: EnvelopeBase.extend({
    kind: z.literal('control'),
    type: z.literal('auth_ok'),
    payload: z.object({
      last_seen_outbound_seq: z.number().int().nonnegative(),
      server_time: z.string().datetime(),
    }),
  }),
  AuthFail: EnvelopeBase.extend({
    kind: z.literal('control'),
    type: z.literal('auth_fail'),
    payload: z.object({ reason: z.string() }),
  }),
  Message: EnvelopeBase.extend({
    kind: z.literal('data'),
    type: z.literal('message'),
    payload: z.object({
      thread_id: z.string().min(1),
      text: z.string(),
      attachments: z.array(z.object({
        id: z.string().uuid(),
        kind: z.enum(['image', 'file']),
        name: z.string(),
        mime_type: z.string(),
        byte_size: z.number().int().nonnegative(),
        bytes_base64: z.string().optional(),
        remote_id: z.string().optional(),
      })).optional(),
      context: InlineContext.optional(),
    }),
  }),
  ContextRequest: EnvelopeBase.extend({
    kind: z.literal('control'),
    type: z.literal('context_request'),
    payload: z.object({
      request_id: z.string().uuid(),
      fields: z.array(ContextFieldEnum).min(1),
      params: z.record(z.string(), z.unknown()).optional(),
    }),
  }),
  ContextResponse: EnvelopeBase.extend({
    kind: z.literal('control'),
    type: z.literal('context_response'),
    payload: z.object({
      request_id: z.string().uuid(),
      data: z.record(z.string(), z.unknown()),
      errors: z.record(z.string(), z.string()).optional(),
    }),
  }),
  NewConversation: EnvelopeBase.extend({
    kind: z.literal('control'),
    type: z.literal('new_conversation'),
    payload: z.object({ thread_id: z.string().min(1) }),
  }),
  ActionResponse: EnvelopeBase.extend({
    kind: z.literal('control'),
    type: z.literal('action_response'),
    payload: z.object({ action_id: z.string(), choice: z.string() }),
  }),
  Feedback: EnvelopeBase.extend({
    kind: z.literal('control'),
    type: z.literal('feedback'),
    payload: z.object({
      message_id: z.string().uuid(),
      kind: z.enum(['up', 'down']),
    }),
  }),
} as const;

// Provisional union — extended in Task 1.4 with ack/ping/pong/status types.
export const AnyEnvelope = z.discriminatedUnion('type', [
  Envelopes.Auth, Envelopes.AuthOk, Envelopes.AuthFail,
  Envelopes.Message, Envelopes.ContextRequest, Envelopes.ContextResponse,
  Envelopes.NewConversation, Envelopes.ActionResponse, Envelopes.Feedback,
]);
export type AnyEnvelope = z.infer<typeof AnyEnvelope>;
