// Wiring for the ios-app v2 protocol adapter.
//
// Pulls together transport-db, OutboundQueue, ReceiptStore, InboundDispatcher,
// ContextBridge, and WsHandler behind a single `registerIosAppV2()` call that
// matches the existing `ChannelAdapter` contract — same registry, same
// onInbound/onAction/deliver surface as the legacy adapter.
//
// NOTE: this module is NOT yet imported by src/channels/index.ts. Wire-up
// happens in Phase 7.1 of the plan. Until then, it's only exercised by tests
// and by the harness under ./testing/.

import http from 'node:http';
import { randomUUID } from 'node:crypto';
import path from 'node:path';
import { WebSocketServer } from 'ws';

import type { ChannelAdapter, ChannelSetup } from '../../adapter.js';
import { registerChannelAdapter } from '../../channel-registry.js';
import { readEnvFile } from '../../../env.js';
import { log } from '../../../log.js';
import { DATA_DIR } from '../../../config.js';
import { getMessagingGroup, getMessagingGroupByPlatform } from '../../../db/messaging-groups.js';
import { findSession, getSession } from '../../../db/sessions.js';
import { writeSessionMessage } from '../../../session-manager.js';

import { openTransportDb } from './transport-db.js';
import { OutboundQueue } from './outbound-queue.js';
import { ReceiptStore } from './receipt-store.js';
import { InboundDispatcher } from './inbound-dispatch.js';
import { ContextBridge } from './context-bridge.js';
import { WsHandler } from './ws-handler.js';
import type { PlatformId, ContextField } from './types.js';

// During the transition window the v2 adapter coexists with the legacy
// `ios-app` adapter. They register under distinct channel names so the
// registry doesn't collide and so existing messaging_groups (channel_type
// `ios-app`) keep flowing through the legacy adapter unchanged. Once the iOS
// app UI is fully on TransportV2, legacy registration is removed and the
// channel_type for those messaging_groups gets migrated to `ios-app-v2`.
const CHANNEL_TYPE = 'ios-app-v2';

function logV2(msg: string, ctx?: Record<string, unknown>): void {
  log.info(`[ios-app-v2] ${msg}`, ctx ?? {});
}
function logV2Warn(msg: string, ctx?: Record<string, unknown>): void {
  log.warn(`[ios-app-v2] ${msg}`, ctx ?? {});
}

/**
 * Resolve `platform_id` → active session id for THIS channel.
 *
 * The plan keeps it scoped to ios-app: look up the messaging_group by
 * (channel_type='ios-app-v2', platform_id), then the active session for that
 * mg (DM, thread-less). When the device is wired to multiple agents (fan-out),
 * we return the first active session; multi-agent fan-out for context routing
 * is out of scope for v2.
 */
function resolveSessionForPlatform(platformId: PlatformId): string | null {
  const mg = getMessagingGroupByPlatform(CHANNEL_TYPE, platformId);
  if (!mg) return null;
  const sess = findSession(mg.id, null);
  return sess?.id ?? null;
}

/**
 * Reverse of the above: given a session id, what device should we ask?
 *
 * Sessions know their `messaging_group_id`; the mg knows its `platform_id`.
 * Returns null when the session has no mg (a2a or system sessions) or the
 * mg is on a different channel.
 */
function resolvePlatformForSession(sessionId: string): PlatformId | null {
  const sess = getSession(sessionId);
  if (!sess?.messaging_group_id) return null;
  const row = getMessagingGroup(sess.messaging_group_id);
  if (!row || row.channel_type !== CHANNEL_TYPE) return null;
  return row.platform_id;
}

function createV2Adapter(): ChannelAdapter | null {
  const env = readEnvFile(['IOS_APP_TOKEN', 'IOS_APP_V2_PORT', 'IOS_APP_V2_DB_PATH']);
  const token = env.IOS_APP_TOKEN;
  if (!token) return null;
  // Transition-window gate: v2 only binds when an explicit port is set. This
  // keeps the legacy adapter the sole holder of the ios-app surface by default
  // (legacy listens on IOS_APP_PORT, typically 3001). To run v2 alongside,
  // operators set IOS_APP_V2_PORT (typical migration: 3002) and rebuild the
  // iOS app pointing at it.
  if (!env.IOS_APP_V2_PORT) return null;
  const port = parseInt(env.IOS_APP_V2_PORT, 10);
  if (!Number.isFinite(port) || port <= 0) {
    logV2Warn('IOS_APP_V2_PORT not a valid port, skipping registration', { value: env.IOS_APP_V2_PORT });
    return null;
  }

  // Default DB path: data/ios-app/transport.db. Override with IOS_APP_V2_DB_PATH
  // (absolute or relative-to-cwd) when running v1 and v2 side-by-side during
  // migration testing.
  const dbPath = env.IOS_APP_V2_DB_PATH
    ? path.isAbsolute(env.IOS_APP_V2_DB_PATH)
      ? env.IOS_APP_V2_DB_PATH
      : path.resolve(process.cwd(), env.IOS_APP_V2_DB_PATH)
    : path.join(DATA_DIR, 'ios-app', 'transport.db');

  const db = openTransportDb(dbPath);
  const queue = new OutboundQueue(db);
  const receipts = new ReceiptStore(db);

  let cfg: ChannelSetup | null = null;
  let httpServer: http.Server | null = null;
  let wss: WebSocketServer | null = null;
  let sweepInterval: NodeJS.Timeout | null = null;

  // Build dispatcher with callbacks that bridge to the host's ChannelSetup
  // (onInbound / onAction). For context responses we bypass routeInbound and
  // write straight into the session's inbound.db — the response carries the
  // request_id which uniquely identifies the originating session.
  const dispatcher = new InboundDispatcher({
    db,
    queue,
    receipts,
    resolveSessionForPlatform,
    onUserMessage: ({ platform_id, envelope }) => {
      if (!cfg) return;
      const ios_context = envelope.payload.context ?? null;
      const attachments = envelope.payload.attachments ?? [];
      const text = envelope.payload.text ?? '';
      const threadId = envelope.payload.thread_id ?? null;
      cfg.onInbound(platform_id, threadId, {
        id: envelope.id,
        kind: 'chat',
        content: {
          text,
          senderId: platform_id,
          ios_context,
          attachments,
        },
        timestamp: envelope.ts ?? new Date().toISOString(),
      });
    },
    onContextResponse: ({ envelope }) => {
      const requestId = envelope.payload.request_id;
      const resolved = contextBridge.resolveDeviceResponse(requestId);
      if (!resolved) {
        logV2Warn('context_response with no pending row', { request_id: requestId });
        return;
      }
      // Write directly to the session's inbound.db — we know exactly which
      // session this is for (the pending_context_requests row told us).
      const sess = getSession(resolved.session_id);
      if (!sess) {
        logV2Warn('context_response for unknown session', { session_id: resolved.session_id });
        return;
      }
      writeSessionMessage(sess.agent_group_id, sess.id, {
        id: randomUUID(),
        kind: 'system',
        timestamp: new Date().toISOString(),
        platformId: null,
        channelType: null,
        threadId: null,
        content: JSON.stringify({
          subtype: 'context_response',
          request_id: requestId,
          data: envelope.payload.data ?? {},
          errors: envelope.payload.errors,
        }),
        trigger: 1,
      });
    },
    onAction: ({ platform_id, envelope }) => {
      if (!cfg) return;
      // ChannelSetup.onAction signature is (questionId, selectedOption, userId).
      // The protocol v2 action_response carries action_id + choice.
      cfg.onAction(envelope.payload.action_id, envelope.payload.choice, platform_id);
    },
    onNewConversation: ({ platform_id, envelope }) => {
      if (!cfg) return;
      // No special host hook — surface as a system inbound so the agent sees
      // a clean break in the thread.
      cfg.onInbound(platform_id, envelope.payload.thread_id ?? null, {
        id: envelope.id,
        kind: 'chat',
        content: {
          text: '[user started a new conversation]',
          senderId: platform_id,
        },
        timestamp: envelope.ts ?? new Date().toISOString(),
      });
    },
    onFeedback: ({ platform_id, envelope }) => {
      if (!cfg) return;
      const positive = envelope.payload.kind === 'up';
      const messageId = envelope.payload.message_id;
      cfg.onInbound(platform_id, null, {
        id: envelope.id,
        kind: 'chat',
        content: {
          text: `[feedback: ${positive ? '👍' : '👎'} on msg ${messageId}]`,
          senderId: platform_id,
        },
        timestamp: envelope.ts ?? new Date().toISOString(),
      });
    },
  });

  // ContextBridge writes inbound `context_response` rows the same way the
  // dispatcher does — wrapped here so the bridge doesn't need to know about
  // the session DB plumbing.
  const writeInboundContextResponse = (input: {
    session_id: string;
    request_id: string;
    data: Record<string, unknown>;
    errors?: Record<string, string>;
  }) => {
    const sess = getSession(input.session_id);
    if (!sess) {
      logV2Warn('context_response for unknown session (synthetic)', { session_id: input.session_id });
      return;
    }
    writeSessionMessage(sess.agent_group_id, sess.id, {
      id: randomUUID(),
      kind: 'system',
      timestamp: new Date().toISOString(),
      platformId: null,
      channelType: null,
      threadId: null,
      content: JSON.stringify({
        subtype: 'context_response',
        request_id: input.request_id,
        data: input.data,
        errors: input.errors,
      }),
      trigger: 1,
    });
  };

  // Forward declarations so the bridge / dispatcher can close over `handler`
  // before it's instantiated.
  let handler: WsHandler;
  const contextBridge = new ContextBridge({
    db,
    resolvePlatformForSession,
    sendEnvelopeToDevice: (pid, envelope) => handler.sendEnvelopeToDevice(pid, envelope),
    writeInboundContextResponse,
  });

  handler = new WsHandler({
    db,
    queue,
    dispatcher,
    contextBridge,
    validateToken: async (clientToken) => {
      // Single shared token model — same as legacy ios-app.ts. The client also
      // sends platform_id alongside the token; we trust it once the token is
      // valid (this matches v1 semantics).
      // Per v2 protocol, the auth payload carries `device_id`. The platform_id
      // is derived as `${CHANNEL_TYPE}:${device_id}` — but ws-handler already
      // calls validateToken with just `payload.token`, so we need to resolve
      // the device id elsewhere. v2 protocol spec stores it in the auth
      // envelope; ws-handler passes only token. For now the platform_id we
      // return is derived from the token assumption: one token = one device.
      //
      // Until the spec is wired through ws-handler, accept any token that
      // equals IOS_APP_TOKEN and return a deterministic platform_id.
      // Phase 7 hardening (and per-device tokens) will replace this.
      if (clientToken !== token) return null;
      // No device discrimination — single-device install. Multi-device support
      // requires ws-handler to surface payload.device_id to validateToken.
      return `${CHANNEL_TYPE}:default`;
    },
  });

  return {
    name: 'ios-app-v2',
    channelType: CHANNEL_TYPE,
    supportsThreads: true,

    async setup(config: ChannelSetup) {
      cfg = config;

      httpServer = http.createServer((req, res) => {
        if (req.method === 'GET' && req.url === '/ios/health') {
          res.writeHead(200, { 'Content-Type': 'application/json' }).end('{"ok":true}');
          return;
        }
        res.writeHead(404).end();
      });

      wss = new WebSocketServer({ server: httpServer });
      handler.attach(wss);

      await new Promise<void>((ok, fail) => httpServer!.listen(port, '0.0.0.0', ok).on('error', fail));

      // Expire pending context_request rows once per second. .unref() so the
      // host can shut down cleanly even if the timer is in flight.
      sweepInterval = setInterval(() => {
        try {
          contextBridge.sweepExpired();
        } catch (err) {
          logV2Warn('sweepExpired threw', { err: err instanceof Error ? err.message : String(err) });
        }
      }, 1000);
      sweepInterval.unref();

      logV2('listening', { port, dbPath });
    },

    async teardown() {
      if (sweepInterval) {
        clearInterval(sweepInterval);
        sweepInterval = null;
      }
      handler.shutdown();
      wss?.close();
      await new Promise<void>((r) => httpServer?.close(() => r()));
      db.raw.close();
    },

    isConnected() {
      return httpServer?.listening ?? false;
    },

    async deliver(platformId, threadId, message) {
      const content = message.content as Record<string, unknown>;
      const contentType = typeof content.type === 'string' ? content.type : undefined;

      // Agent-initiated context pull — route through ContextBridge, which
      // persists a pending row and pushes a control:context_request to the
      // device. Returns the request id so the caller can correlate.
      if (contentType === 'context_request') {
        const requestId = (content.requestId as string) ?? randomUUID();
        // Find the session that emitted this — we infer it from the platform_id
        // since (channel, platform_id) → mg → session is unique for DMs.
        const sessionId = resolveSessionForPlatform(platformId);
        if (!sessionId) {
          logV2Warn('context_request with no active session', { platformId });
          return requestId;
        }
        const fields = (content.fields as ContextField[]) ?? [];
        const params = (content.params as Record<string, unknown>) ?? {};
        const ttlMs = typeof content.ttl_ms === 'number' ? content.ttl_ms : 30_000;
        contextBridge.handleAgentRequest({
          session_id: sessionId,
          request_id: requestId,
          fields,
          params,
          expires_at_ms: Date.now() + ttlMs,
        });
        return requestId;
      }

      // Default outbound: enqueue as a chat message envelope. WsHandler
      // allocates the seq and flushes to the device if the socket is live.
      const id = (content.id as string) ?? randomUUID();
      const kind = message.kind === 'system' || message.kind === 'control' ? message.kind : 'chat';
      const type = (content.type as string) ?? 'message';

      handler.sendEnvelopeToDevice(platformId, {
        id,
        kind,
        type,
        payload: {
          ...content,
          conversation_id: threadId ?? undefined,
        },
      });
      return id;
    },
  };
}

/**
 * Register the v2 ios-app adapter with the channel registry.
 *
 * Registers under the distinct name `ios-app-v2` so the legacy `ios-app`
 * adapter (still bound to messaging_groups with channel_type='ios-app') can
 * coexist during the migration window. The factory itself short-circuits to
 * null unless `IOS_APP_V2_PORT` is set in the env, so the default behavior is
 * "v2 is a no-op; legacy serves all iOS traffic".
 */
export function registerIosAppV2(): void {
  registerChannelAdapter('ios-app-v2', { factory: createV2Adapter });
}

// Re-export the internals so harness/integration tests can construct a fully
// wired adapter without touching the registry.
export { createV2Adapter };
