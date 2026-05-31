import type { AnyEnvelope, InlineContext, ContextField } from '../../../../shared/ios-app-protocol/index.js';

export type PlatformId = string; // `ios-app:<deviceId>`

export interface DeviceRow {
  platform_id: PlatformId;
  last_seen_outbound_seq: number; // highest app→adapter seq we persisted
  last_emitted_inbound_seq: number; // highest adapter→app seq we allocated
  capabilities_json: string | null;
  updated_at: number;
}

export interface OutboundQueueRow {
  platform_id: PlatformId;
  seq: number;
  id: string;
  kind: string;
  type: string;
  payload_json: string;
  created_at: number;
}

export interface InboundDedupRow {
  platform_id: PlatformId;
  id: string;
  seq: number;
  received_at: number;
}

export interface PendingContextRequestRow {
  request_id: string;
  platform_id: PlatformId;
  session_id: string;
  fields_json: string;
  created_at: number;
  expires_at: number;
}

// Re-export for downstream files to consume types via this internal module.
export type { AnyEnvelope, InlineContext, ContextField };

export const MAX_QUEUE_PER_DEVICE = 1000;
export const DEDUP_TTL_MS = 24 * 60 * 60 * 1000;
export const ACK_RETRY_MS = 5_000;
export const APP_PING_INTERVAL_MS = 60_000;
export const WS_PING_INTERVAL_MS = 25_000;
export const WS_PONG_TIMEOUT_MS = 10_000;
