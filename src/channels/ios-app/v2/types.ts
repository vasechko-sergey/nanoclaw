import type { AnyEnvelope, InlineContext, ContextField } from '../../../../shared/ios-app-protocol/index.js';

export type PlatformId = string; // `ios-app:<deviceId>`

export interface DeviceRow {
  platform_id: PlatformId;
  last_seen_outbound_seq: number; // highest app→adapter seq we persisted
  last_emitted_inbound_seq: number; // highest adapter→app seq we allocated
  capabilities_json: string | null;
  app_version: string | null; // CFBundleShortVersionString reported on auth
  app_build: string | null; // CFBundleVersion reported on auth
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

/**
 * Most attachment bytes (raw, all files together) one outbound message may
 * carry. Attachments ride inline as base64 in a single WebSocket frame, so this
 * is what bounds the frame; deliver() names a file that doesn't fit in the text
 * instead of sending it.
 */
export const MAX_ATTACHMENT_BYTES = 30 * 1024 * 1024;

/**
 * The iOS app's WebSocket receive limit (`URLSessionWebSocket.maxMessageBytes`).
 * A bigger frame fails the receive and closes the socket with 1009; the row is
 * never acked, so every reconnect re-drains it first and the device never
 * recovers. Base64 inflates MAX_ATTACHMENT_BYTES by 4/3 (30 → 40 MiB), which
 * leaves 8 MiB here for the text and JSON.
 */
export const CLIENT_MAX_FRAME_BYTES = 48 * 1024 * 1024;

/**
 * Outbound envelope types the device should raise a local notification for.
 * The notification pull (`GET /ios/pending`) and the device-side notifier are
 * both restricted to these. `message` only for the MVP; extend (e.g.
 * `coach_message`) when those become notification-worthy.
 */
export const NOTIFY_TYPES = ['message', 'summary_ready'] as const;
export const DEDUP_TTL_MS = 24 * 60 * 60 * 1000;
export const ACK_RETRY_MS = 5_000;
export const APP_PING_INTERVAL_MS = 60_000;
export const WS_PING_INTERVAL_MS = 25_000;
export const WS_PONG_TIMEOUT_MS = 10_000;
