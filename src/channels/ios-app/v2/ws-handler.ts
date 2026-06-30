// WebSocket handler for ios-app protocol v2.
//
// Responsibilities (per protocol §"Adapter Internals"):
//   - Handshake: accept the client's control:auth as the first envelope,
//     validate the token, reply with control:auth_ok or close 4003.
//   - Singleton socket per platform_id: superseding connections close the
//     prior socket with 4004 superseded.
//   - Drain outbound queue on connect (already-persisted server→client
//     messages whose seq > client's last_seen_inbound_seq).
//   - Per-inbound dispatch via InboundDispatcher. Translate the returned
//     DispatchAction into ack:ack or control:pong frames.
//   - Retry timer: every 1s, resend outbound rows whose age exceeds
//     ACK_RETRY_MS (5s) — assumes client lost them.
//   - App-level keepalive: send control:ping every APP_PING_INTERVAL_MS
//     (60s). This is the protocol-level ping, distinct from ws low-level
//     PING frames; the client replies with control:pong { nonce }.
//   - Ping isolation: pong handling MUST NOT touch inbound_dedup, MUST NOT
//     advance the inbound cursor, MUST NOT enqueue an outbound row. The
//     dispatcher already enforces this; this handler must not double-write.
//
// Close codes (RFC 6455 application range 4000-4999):
//   4002 protocol_violation — frame failed schema parse / wrong shape.
//   4003 auth_failed         — no auth received in 10s, or invalid token.
//   4004 superseded          — same platform_id reconnected.

import { randomUUID } from 'node:crypto';
import { WebSocketServer, WebSocket } from 'ws';
import { log } from '../../../log.js';
import { AnyEnvelope } from '../../../../shared/ios-app-protocol/index.js';
import type { TransportDb } from './transport-db.js';
import type { OutboundQueue } from './outbound-queue.js';
import type { InboundDispatcher } from './inbound-dispatch.js';
import type { ContextBridge } from './context-bridge.js';
import type { ImageCache } from './image-cache.js';
import { convertImageBlobToRef } from './image-ref.js';
import { ACK_RETRY_MS, APP_PING_INTERVAL_MS, type PlatformId } from './types.js';

export const CLOSE_CODES = {
  protocol_violation: 4002,
  auth_failed: 4003,
  superseded: 4004,
} as const;

const AUTH_TIMEOUT_MS = 10_000;

export interface WsHandlerDeps {
  db: TransportDb;
  queue: OutboundQueue;
  dispatcher: InboundDispatcher;
  contextBridge: ContextBridge;
  /**
   * Host-side image byte cache. When present, an outbound `image_blob` to a
   * capability-`image_ref` device is rewritten to a tiny `image_ready` ref and
   * its bytes are cached for HTTP fetch — keeping multi-MB base64 off the
   * realtime stream. Absent → no conversion (legacy inline-blob path).
   */
  imageCache?: ImageCache;
  validateToken: (token: string) => Promise<PlatformId | null>;
  /**
   * Optional slash-command catalogue published on every `auth_ok`. The iOS
   * `UnifiedInputBar` consumes this to populate its suggestion popover.
   * Commands are expected to be `/`-prefixed (matches legacy adapter shape).
   */
  commands?: Array<{ command: string; description: string }>;
  /**
   * Test/escape hatch: how often the retry timer fires. Default 1000ms.
   * Lower values make retry tests faster but should not be used in prod.
   */
  retryTickMs?: number;
  /**
   * Test/escape hatch: how stale a row must be before retry resends it.
   * Default ACK_RETRY_MS (5000ms).
   */
  retryAgeMs?: number;
  /**
   * Test/escape hatch: app-level ping interval. Default APP_PING_INTERVAL_MS.
   */
  appPingMs?: number;
}

interface ConnState {
  ws: WebSocket;
  platform_id: PlatformId;
  retryInterval: NodeJS.Timeout;
  appPingInterval: NodeJS.Timeout;
}

export class WsHandler {
  private sockets = new Map<PlatformId, ConnState>();
  private retryTickMs: number;
  private retryAgeMs: number;
  private appPingMs: number;
  private stopped = false;

  constructor(private deps: WsHandlerDeps) {
    this.retryTickMs = deps.retryTickMs ?? 1000;
    this.retryAgeMs = deps.retryAgeMs ?? ACK_RETRY_MS;
    this.appPingMs = deps.appPingMs ?? APP_PING_INTERVAL_MS;
  }

  attach(server: WebSocketServer): void {
    server.on('connection', (ws) => this.onConnection(ws));
  }

  /**
   * Public entry for ContextBridge / agent outputs: persist an envelope into
   * the outbound queue (allocating a fresh seq) and, if the device is live,
   * push the materialized envelope down the wire. Retry timer covers the
   * offline case.
   *
   * The caller supplies kind/type/payload (and optionally id/ts). seq is
   * always allocated server-side — any seq on the input is ignored.
   */
  sendEnvelopeToDevice(platform_id: PlatformId, envelope: any): void {
    // Keep multi-MB image bytes off the realtime stream: rewrite image_blob →
    // image_ready (and cache the bytes host-side) for ref-capable devices. A
    // no-op for every other envelope type and for legacy clients.
    if (this.deps.imageCache) {
      envelope = convertImageBlobToRef(
        envelope,
        this.deviceSupportsImageRef(platform_id),
        this.deps.imageCache,
        (msg, ctx) => log.warn(`[ios-app-v2] ${msg}`, ctx),
      );
    }
    const id = envelope.id ?? randomUUID();
    const seq = this.deps.queue.enqueue(platform_id, {
      id,
      kind: envelope.kind,
      type: envelope.type,
      payload: envelope.payload,
    });
    const conn = this.sockets.get(platform_id);
    if (!conn || conn.ws.readyState !== WebSocket.OPEN) {
      // [delivery] trace: enqueued but no live socket — will be drained on the
      // device's next connect. Grep `[delivery]` across host + device logs.
      log.info('[delivery] queued (offline)', { to: platform_id, type: envelope.type, id, seq });
      return;
    }
    const fullEnvelope = {
      v: 2,
      kind: envelope.kind,
      type: envelope.type,
      id,
      seq,
      ts: envelope.ts ?? new Date().toISOString(),
      payload: envelope.payload,
    };
    this.sendRaw(conn.ws, fullEnvelope);
    log.info('[delivery] push', { to: platform_id, type: envelope.type, id, seq });
  }

  /**
   * Stop all timers + drop socket map. Used by tests; in prod the process
   * exit clears intervals anyway.
   */
  shutdown(): void {
    this.stopped = true;
    for (const conn of this.sockets.values()) {
      clearInterval(conn.retryInterval);
      clearInterval(conn.appPingInterval);
      try {
        conn.ws.terminate();
      } catch {
        // ignore
      }
    }
    this.sockets.clear();
  }

  /** True if the device advertised the `image_ref` capability on its last auth. */
  private deviceSupportsImageRef(pid: PlatformId): boolean {
    const caps = this.deps.db.getDevice(pid)?.capabilities_json;
    if (!caps) return false;
    try {
      return (JSON.parse(caps) as unknown[]).includes('image_ref');
    } catch {
      return false;
    }
  }

  private onConnection(ws: WebSocket): void {
    let platform_id: PlatformId | null = null;

    const authTimer = setTimeout(() => {
      if (!platform_id && ws.readyState === WebSocket.OPEN) {
        ws.close(CLOSE_CODES.auth_failed, 'auth_timeout');
      }
    }, AUTH_TIMEOUT_MS);

    ws.on('message', async (raw) => {
      let env: AnyEnvelope;
      try {
        env = AnyEnvelope.parse(JSON.parse(raw.toString()));
      } catch (err) {
        clearTimeout(authTimer);
        // [delivery] diag: capture the exact frame the device sent that fails
        // AnyEnvelope — this is what triggers the 4002 reconnect storm. Truncated
        // to keep the log sane; the Zod message names the failing field/type.
        log.warn('[delivery] protocol_violation — unparseable frame', {
          platform_id: platform_id ?? '(pre-auth)',
          raw: raw.toString().slice(0, 600),
          error: String((err as Error)?.message ?? err).slice(0, 500),
        });
        ws.close(CLOSE_CODES.protocol_violation, 'protocol_violation');
        return;
      }

      if (!platform_id) {
        if (env.type !== 'auth') {
          clearTimeout(authTimer);
          ws.close(CLOSE_CODES.auth_failed, 'expected_auth');
          return;
        }
        const pid = await this.deps.validateToken(env.payload.token);
        if (!pid) {
          clearTimeout(authTimer);
          ws.close(CLOSE_CODES.auth_failed, 'invalid_token');
          return;
        }
        clearTimeout(authTimer);
        platform_id = pid;
        this.attachAuthed(ws, pid, env);
        return;
      }

      // Post-auth dispatch.
      // [delivery] diag: what the device sends back post-auth (ack/delivered/
      // read/pong). Tells us whether a drained message was processed before the
      // socket died — pairs with `[delivery] socket close` below.
      log.info('[delivery] recv-from-device', { platform_id, type: env.type, id: env.id });
      const action = this.deps.dispatcher.dispatch(platform_id, env);
      if (action.kind === 'ack') {
        this.sendRaw(ws, {
          v: 2,
          kind: 'ack',
          type: 'ack',
          id: randomUUID(),
          seq: null,
          ts: new Date().toISOString(),
          payload: { id: env.id, seq: env.seq ?? 0 },
        });
      } else if (action.kind === 'pong') {
        this.sendRaw(ws, {
          v: 2,
          kind: 'control',
          type: 'pong',
          id: randomUUID(),
          seq: null,
          ts: new Date().toISOString(),
          payload: { nonce: action.nonce },
        });
      }
      // 'noop' (e.g. ack/delivered/read envelopes from the client) — nothing.
    });

    ws.on('close', (code: number, reason: Buffer) => {
      clearTimeout(authTimer);
      // [delivery] diag: WS close code + reason. 1000=normal, 1001=going away
      // (backgrounded), 1006=abnormal/no-close-frame (network/proxy drop),
      // 1002/1003=protocol/unsupported-data, 4xxx=our CLOSE_CODES (superseded etc).
      log.info('[delivery] socket close', {
        platform_id: platform_id ?? '(pre-auth)',
        code,
        reason: reason?.toString() || undefined,
      });
      if (!platform_id) return;
      const conn = this.sockets.get(platform_id);
      if (conn && conn.ws === ws) {
        clearInterval(conn.retryInterval);
        clearInterval(conn.appPingInterval);
        this.sockets.delete(platform_id);
      }
    });

    ws.on('error', (err: Error) => {
      log.warn('[delivery] socket error', {
        platform_id: platform_id ?? '(pre-auth)',
        error: String(err?.message ?? err),
      });
      // ws library will follow with 'close' — cleanup handled there.
    });
  }

  private attachAuthed(ws: WebSocket, pid: PlatformId, auth: Extract<AnyEnvelope, { type: 'auth' }>): void {
    // Persist the reported app version/build so the installed build is knowable
    // server-side (queryable from the devices row), not guessed.
    this.deps.db.upsertDevice(pid, {
      capabilities: auth.payload.capabilities,
      app_version: auth.payload.app_version,
      build: auth.payload.build,
    });
    // Client tells us the highest inbound seq it has acked. Drop everything
    // up to and including that from the queue — no need to retransmit.
    this.deps.queue.ackUpTo(pid, auth.payload.last_seen_inbound_seq);

    // Supersede any prior live socket for this device.
    const prev = this.sockets.get(pid);
    const superseding = !!(prev && prev.ws !== ws);
    if (prev && prev.ws !== ws) {
      // [delivery] trace: a second connection for the SAME platform_id (e.g. a
      // simulator AND a phone sharing one token) takes over the socket. The
      // displaced device stops receiving pushes — a classic cause of "message
      // never arrived on my device".
      log.warn('[delivery] supersede', { platform_id: pid, build: auth.payload.build });
      clearInterval(prev.retryInterval);
      clearInterval(prev.appPingInterval);
      this.sockets.delete(pid);
      if (prev.ws.readyState === WebSocket.OPEN) {
        prev.ws.close(CLOSE_CODES.superseded, 'superseded');
      }
    }
    log.info('[delivery] auth', {
      platform_id: pid,
      build: auth.payload.build,
      app_version: auth.payload.app_version,
      superseding,
      lastSeenInbound: auth.payload.last_seen_inbound_seq,
    });

    const dev = this.deps.db.getDevice(pid);
    // upsertDevice above guarantees the row exists.
    const last_seen_outbound_seq = dev?.last_seen_outbound_seq ?? 0;

    const authOkPayload: Record<string, unknown> = {
      last_seen_outbound_seq,
      server_time: new Date().toISOString(),
    };
    if (this.deps.commands && this.deps.commands.length > 0) {
      authOkPayload.commands = this.deps.commands;
    }
    this.sendRaw(ws, {
      v: 2,
      kind: 'control',
      type: 'auth_ok',
      id: randomUUID(),
      seq: null,
      ts: new Date().toISOString(),
      payload: authOkPayload,
    });

    // Drain pending queue rows (everything still there post-ackUpTo).
    for (const row of this.deps.queue.list(pid)) {
      this.sendRaw(ws, {
        v: 2,
        kind: row.kind,
        type: row.type,
        id: row.id,
        seq: row.seq,
        // Authored/enqueue time, NOT send time: a row drained from the offline
        // queue minutes/hours late must keep its original timestamp so the iOS
        // client (which orders the chat by `ts`) doesn't sort it after newer
        // messages. created_at is set once at enqueue (outbound-queue.ts).
        ts: new Date(row.created_at).toISOString(),
        payload: JSON.parse(row.payload_json),
      });
      log.info('[delivery] drain', { to: pid, type: row.type, id: row.id, seq: row.seq });
    }

    const retryInterval = setInterval(() => this.tickRetry(pid), this.retryTickMs);
    const appPingInterval = setInterval(() => this.sendAppPing(pid), this.appPingMs);
    this.sockets.set(pid, { ws, platform_id: pid, retryInterval, appPingInterval });
  }

  private tickRetry(pid: PlatformId): void {
    if (this.stopped) return;
    const conn = this.sockets.get(pid);
    if (!conn || conn.ws.readyState !== WebSocket.OPEN) return;
    const cutoff = Date.now() - this.retryAgeMs;
    const rows = this.deps.queue.listOlderThan(pid, cutoff);
    for (const row of rows) {
      this.sendRaw(conn.ws, {
        v: 2,
        kind: row.kind,
        type: row.type,
        id: row.id,
        seq: row.seq,
        // Authored/enqueue time, NOT send time: a row drained from the offline
        // queue minutes/hours late must keep its original timestamp so the iOS
        // client (which orders the chat by `ts`) doesn't sort it after newer
        // messages. created_at is set once at enqueue (outbound-queue.ts).
        ts: new Date(row.created_at).toISOString(),
        payload: JSON.parse(row.payload_json),
      });
    }
  }

  private sendAppPing(pid: PlatformId): void {
    if (this.stopped) return;
    const conn = this.sockets.get(pid);
    if (!conn || conn.ws.readyState !== WebSocket.OPEN) return;
    this.sendRaw(conn.ws, {
      v: 2,
      kind: 'control',
      type: 'ping',
      id: randomUUID(),
      seq: null,
      ts: new Date().toISOString(),
      payload: { nonce: randomUUID() },
    });
  }

  private sendRaw(ws: WebSocket, env: unknown): void {
    if (ws.readyState !== WebSocket.OPEN) return;
    ws.send(JSON.stringify(env));
  }
}
