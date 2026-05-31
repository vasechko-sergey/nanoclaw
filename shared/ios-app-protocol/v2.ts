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
