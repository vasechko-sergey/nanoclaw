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
import { adapterRouteToAgent } from '../../../adapter-route.js';
import { readEnvFile } from '../../../env.js';
import { log } from '../../../log.js';
import { DATA_DIR, GROUPS_DIR, OWNER_PERSON_KEY } from '../../../config.js';
import { resolveIosToken, upsertIosToken } from './token-registry.js';
import { upsertUser, getUser } from '../../../modules/permissions/db/users.js';
import {
  getMessagingGroup,
  getMessagingGroupByPlatform,
  getMessagingGroupAgents,
} from '../../../db/messaging-groups.js';
import { getAgentGroup, getAgentGroupByFolder } from '../../../db/agent-groups.js';
import { findSession, findSessionForAgent, getSession } from '../../../db/sessions.js';
import { writeSessionMessage } from '../../../session-manager.js';

import { BOT_COMMANDS } from '../../../commands.js';
import { openTransportDb } from './transport-db.js';
import { OutboundQueue } from './outbound-queue.js';
import { ReceiptStore } from './receipt-store.js';
import { InboundDispatcher } from './inbound-dispatch.js';
import { ContextBridge } from './context-bridge.js';
import { WorkoutBridge } from './workout-bridge.js';
import { WsHandler } from './ws-handler.js';
import { HealthRequestsStore } from './health-requests-store.js';
import { createIosHttpHandler } from './http-handler.js';
import type { PlatformId, ContextField } from './types.js';

// During the transition window the v2 adapter coexists with the legacy
// `ios-app` adapter. They register under distinct channel names so the
// registry doesn't collide and so existing messaging_groups (channel_type
// `ios-app`) keep flowing through the legacy adapter unchanged. Once the iOS
// app UI is fully on TransportV2, legacy registration is removed and the
// channel_type for those messaging_groups gets migrated to `ios-app-v2`.
const CHANNEL_TYPE = 'ios-app-v2';

function mimeFromFilename(name: string): string {
  const ext = path.extname(name).toLowerCase();
  switch (ext) {
    case '.jpg':
    case '.jpeg':
      return 'image/jpeg';
    case '.png':
      return 'image/png';
    case '.gif':
      return 'image/gif';
    case '.webp':
      return 'image/webp';
    case '.heic':
      return 'image/heic';
    case '.heif':
      return 'image/heif';
    case '.pdf':
      return 'application/pdf';
    case '.txt':
      return 'text/plain';
    case '.md':
      return 'text/markdown';
    case '.json':
      return 'application/json';
    default:
      return 'application/octet-stream';
  }
}

function logV2(msg: string, ctx?: Record<string, unknown>): void {
  log.info(`[ios-app-v2] ${msg}`, ctx ?? {});
}
function logV2Warn(msg: string, ctx?: Record<string, unknown>): void {
  log.warn(`[ios-app-v2] ${msg}`, ctx ?? {});
}

/**
 * Resolve `(platform_id, agent_id)` → active session id for THIS channel.
 *
 * Look up the messaging_group by (channel_type='ios-app-v2', platform_id).
 * When the device tags an inbound envelope with `agent_id` (a slug equal
 * to the agent group's folder), pick the session belonging to that agent
 * via `findSessionForAgent`. If no such per-agent session exists yet —
 * e.g. agent slug typo, agent not wired, session not yet created — fall
 * back to the default session for the mg.
 */
function resolveSessionForPlatform(platformId: PlatformId, agentId: string | undefined): string | null {
  const mg = getMessagingGroupByPlatform(CHANNEL_TYPE, platformId);
  if (!mg) return null;
  if (agentId) {
    // Match the authoritative router (adapter-route.ts): resolve by folder
    // OR by id. The device may target by either; id-targeting (e.g. greg /
    // scrooge whose id === folder, or jarvis whose id is a UUID) otherwise
    // tripped the "no matching agent_group" warning even though routing
    // downstream resolved it fine.
    const ag = getAgentGroupByFolder(agentId) ?? getAgentGroup(agentId);
    if (ag) {
      const sess = findSessionForAgent(ag.id, mg.id, null);
      if (sess) return sess.id;
      // Normal steady state before the agent's first message: the session is
      // created on demand by adapterRouteToAgent → resolveSession. Not a
      // routing error (this return value is unused for chat envelopes), so
      // log at info, not warn.
      logV2('agent_id provided but no per-agent session yet, will create on route', {
        platform_id: platformId,
        agent_id: agentId,
        messaging_group_id: mg.id,
      });
    } else {
      logV2Warn('agent_id provided but no matching agent_group found, falling back to mg default', {
        platform_id: platformId,
        agent_id: agentId,
      });
    }
    // Fall through to default mg session if no agent-scoped session exists.
  }
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
  const env = readEnvFile(['IOS_APP_TOKEN', 'IOS_APP_V2_PORT', 'IOS_APP_V2_DB_PATH', 'IOS_APP_DEFAULT_AGENT_SLUG']);
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

  // Slug used when an inbound envelope omits `agent_id`. Devices that don't
  // yet send `agent_id` (older iOS builds) and the legacy single-agent
  // install both fall through to this name. `jarvis` is the conventional
  // default for this codebase.
  const defaultAgentSlug = env.IOS_APP_DEFAULT_AGENT_SLUG ?? 'jarvis';

  const db = openTransportDb(dbPath);
  const queue = new OutboundQueue(db);
  const receipts = new ReceiptStore(db);
  const healthRequestsStore = new HealthRequestsStore(db);

  // Where health daily aggregates land on disk. Defaults to GROUPS_DIR (so
  // each device's wired agent group gets its own raw.jsonl); legacy installs
  // pinned a single shared directory via IOS_HEALTH_HISTORY_DIR — honor that
  // override for back-compat. Absolute paths supported; relative paths
  // resolve against cwd.
  const healthEnv = readEnvFile(['IOS_HEALTH_HISTORY_DIR']);
  const healthOverrideDir = healthEnv.IOS_HEALTH_HISTORY_DIR
    ? path.isAbsolute(healthEnv.IOS_HEALTH_HISTORY_DIR)
      ? healthEnv.IOS_HEALTH_HISTORY_DIR
      : path.resolve(process.cwd(), healthEnv.IOS_HEALTH_HISTORY_DIR)
    : null;

  let cfg: ChannelSetup | null = null;
  let httpServer: http.Server | null = null;
  let wss: WebSocketServer | null = null;
  let sweepInterval: NodeJS.Timeout | null = null;

  // Forward-declare so the bridges below can close over `handler` before it's
  // instantiated. Both ContextBridge and WorkoutBridge need to push envelopes
  // via the WS handler; the handler in turn needs the dispatcher (and the
  // dispatcher needs WorkoutBridge), so the only way to break the cycle is
  // via a captured `let`-binding.
  let handler: WsHandler;

  const workoutBridge = new WorkoutBridge({
    writeInboundSystemMessage: (input) => {
      const sess = getSession(input.session_id);
      if (!sess) {
        logV2Warn('workout event for unknown session', { session_id: input.session_id });
        return;
      }
      // Bridge body is JSON-encoded `{ event, payload }`; wrap it with
      // `subtype: 'workout_event'` and propagate `tag` so the agent's
      // inbound parser sees a stable envelope (mirrors `context_response`).
      const parsed = JSON.parse(input.text) as { event: string; payload: unknown };
      writeSessionMessage(sess.agent_group_id, sess.id, {
        id: randomUUID(),
        kind: 'system',
        timestamp: new Date().toISOString(),
        platformId: null,
        channelType: null,
        threadId: null,
        content: JSON.stringify({
          subtype: 'workout_event',
          event: parsed.event,
          payload: parsed.payload,
          tag: input.tag,
        }),
        trigger: 1,
      });
    },
    resolvePlatformForSession,
    sendEnvelopeToDevice: (pid, envelope) => handler.sendEnvelopeToDevice(pid, envelope),
  });

  // Build dispatcher with callbacks that bridge to the host's ChannelSetup
  // (onInbound / onAction). For context responses we bypass routeInbound and
  // write straight into the session's inbound.db — the response carries the
  // request_id which uniquely identifies the originating session.
  const dispatcher = new InboundDispatcher({
    db,
    queue,
    receipts,
    resolveSessionForPlatform,
    defaultAgentSlug,
    routeToAgent: ({ platform_id, agent_group_id, envelope }) => {
      void adapterRouteToAgent(
        {
          channelType: CHANNEL_TYPE,
          platformId: platform_id,
          threadId: envelope.payload.thread_id ?? null,
          message: {
            id: envelope.id,
            kind: 'chat',
            content: JSON.stringify({
              text: envelope.payload.text ?? '',
              senderId: platform_id,
              ios_context: envelope.payload.context ?? null,
              attachments: envelope.payload.attachments ?? [],
            }),
            timestamp: envelope.ts ?? new Date().toISOString(),
          },
        },
        agent_group_id,
      ).catch((err) => logV2Warn('routeToAgent threw', { err: String(err), agent_group_id }));
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
    workoutBridge,
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
    commands: BOT_COMMANDS.map((c) => ({
      command: '/' + c.command,
      description: c.description,
    })),
    validateToken: async (clientToken) => {
      // Per-person token model: the bearer token resolves (via the ios_tokens
      // registry) to a platform_id + person_key. Unknown tokens are rejected.
      // The owner's legacy IOS_APP_TOKEN is seeded into the registry in setup()
      // so the single-token install keeps authenticating with zero manual steps.
      const identity = resolveIosToken(clientToken);
      if (!identity) return null;
      // Ensure a users row keyed by the platform_id carries this device's
      // person_key, so resolvePersonKey(senderId=platform_id) → person_key
      // and adapter-route stamps session.owner_key correctly.
      const existing = getUser(identity.platform_id);
      if (!existing || existing.person_key !== identity.person_key) {
        upsertUser({
          id: identity.platform_id,
          kind: CHANNEL_TYPE,
          display_name: existing?.display_name ?? null,
          person_key: identity.person_key,
          created_at: new Date().toISOString(),
        });
      }
      return identity.platform_id;
    },
  });

  return {
    name: 'ios-app-v2',
    channelType: CHANNEL_TYPE,
    supportsThreads: true,

    async setup(config: ChannelSetup) {
      cfg = config;

      // Back-compat: map the legacy shared IOS_APP_TOKEN → the owner's existing
      // platform_id so the owner's device keeps authenticating after the cutover.
      // New people get their own tokens via scripts/mint-ios-token.ts. Seeded
      // here (not in the factory body) because setup() runs at host start, after
      // the central DB is initialized — so getDb() is guaranteed valid.
      // Idempotent: upsertIosToken clears any prior row for this platform_id.
      if (token) {
        try {
          upsertIosToken({
            rawToken: token,
            platformId: `${CHANNEL_TYPE}:default`,
            personKey: OWNER_PERSON_KEY,
            label: 'owner (legacy IOS_APP_TOKEN)',
          });
        } catch (err) {
          logV2Warn('failed to seed owner ios token', {
            err: err instanceof Error ? err.message : String(err),
          });
        }
      }

      // Resolve the agent group folder wired to a device's messaging group.
      // Multi-agent fan-out: take highest-priority wiring (the order
      // getMessagingGroupAgents returns).
      const resolveAgentFolderForPlatform = (platformId: PlatformId): string | null => {
        const mg = getMessagingGroupByPlatform(CHANNEL_TYPE, platformId);
        if (!mg) return null;
        const wirings = getMessagingGroupAgents(mg.id);
        if (wirings.length === 0) return null;
        const agentGroup = getAgentGroup(wirings[0].agent_group_id);
        return agentGroup?.folder ?? null;
      };

      const httpHandler = createIosHttpHandler({
        token,
        healthRequestsStore,
        resolveAgentFolderForPlatform,
        groupsDir: GROUPS_DIR,
        healthOverrideDir,
        getChannelSetup: () => cfg,
        log: logV2,
        logWarn: logV2Warn,
      });
      httpServer = http.createServer(httpHandler);

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
        // For agent-initiated context pulls we don't know which agent slug
        // the agent's session belongs to from this side — but every context
        // request originates from a session that's already tied to one
        // messaging_group, so the default-mg session resolution is correct.
        const sessionId = resolveSessionForPlatform(platformId, undefined);
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

      // Workout-bridge outbound — agent emits content like
      //   { type: 'workout_plan', payload: { ... } }
      // We hand it straight to the bridge which constructs the v2 envelope.
      if (contentType && workoutBridge.handlesOutbound(contentType)) {
        const sessionId = resolveSessionForPlatform(platformId, undefined);
        if (!sessionId) {
          logV2Warn('workout outbound with no active session', { platformId, type: contentType });
          return undefined;
        }
        workoutBridge.handleAgentRequest({ session_id: sessionId, content });
        return undefined;
      }

      // Default outbound: enqueue as a v2 data:message envelope so the iOS
      // Codable mirror accepts it. WsHandler allocates the seq and flushes
      // to the device if the socket is live.
      const id = (content.id as string) ?? randomUUID();
      const text =
        typeof content.text === 'string' && content.text.length > 0
          ? content.text
          : typeof content.caption === 'string'
            ? content.caption
            : '';
      // File buffers are loaded from the session outbox by delivery.ts and
      // arrive on `message.files` as OutboundFile[]. The agent's raw
      // `content.files` is just a list of filename strings — those are not
      // useful to the device. Encode the buffers as base64 attachments here.
      const attachments =
        Array.isArray(message.files) && message.files.length > 0
          ? message.files.map((f) => {
              const mime = mimeFromFilename(f.filename);
              return {
                id: randomUUID(),
                kind: mime.startsWith('image/') ? 'image' : 'file',
                name: f.filename,
                mime_type: mime,
                byte_size: f.data.length,
                bytes_base64: f.data.toString('base64'),
                remote_id: undefined as string | undefined,
              };
            })
          : undefined;

      // If the caller (delivery.ts) supplied the originating agent_group_id,
      // resolve it to the canonical folder slug and stamp it on the envelope
      // so the iOS app can route the reply into the per-agent thread. If the
      // lookup fails — group deleted, missing folder — log and omit the field
      // (device falls back to its default-agent behavior).
      const agentGroupId = message.agentGroupId;
      let agentFolder: string | undefined;
      if (agentGroupId) {
        const group = getAgentGroup(agentGroupId);
        if (group?.folder) {
          agentFolder = group.folder;
        } else {
          logV2Warn('outbound agent_group not found, omitting agent_id', {
            agent_group_id: agentGroupId,
          });
        }
      }

      handler.sendEnvelopeToDevice(platformId, {
        id,
        kind: 'data',
        type: 'message',
        payload: {
          thread_id: threadId ?? 'default',
          text,
          ...(attachments && attachments.length > 0 ? { attachments } : {}),
          ...(agentFolder ? { agent_id: agentFolder } : {}),
        },
      });
      return id;
    },
  };
}

/**
 * Register the v2 ios-app adapter with the channel registry.
 *
 * Registers under the name `ios-app-v2`. The legacy `ios-app` adapter has
 * been removed, so this is the only iOS transport — operators migrate any
 * remaining `channel_type='ios-app'` messaging-group rows to `'ios-app-v2'`.
 * The factory short-circuits to null unless `IOS_APP_V2_PORT` is set, so iOS
 * traffic is served only when that env var is configured.
 */
export function registerIosAppV2(): void {
  registerChannelAdapter('ios-app-v2', { factory: createV2Adapter });
}

// Re-export the internals so harness/integration tests can construct a fully
// wired adapter without touching the registry.
export { createV2Adapter };
