import fs from 'node:fs';
import http from 'node:http';
import http2 from 'node:http2';
import path from 'node:path';
import { createSign, randomUUID } from 'node:crypto';
import { WebSocketServer, WebSocket } from 'ws';
import { BOT_COMMANDS } from '../commands.js';
import { readEnvFile } from '../env.js';
import { registerChannelAdapter } from './channel-registry.js';
import type { ChannelAdapter, ChannelSetup } from './adapter.js';
import { ReadReceiptStore } from './ios-read-receipts.js';

function log(msg: string): void {
  console.log(`[ios-app] ${msg}`);
}

// Max messages buffered for an offline device before dropping the oldest.
const MAX_PENDING_PER_DEVICE = 200;

// APNs JWT — reused for 55 min then refreshed
let apnsJwt: { token: string; createdAt: number } | null = null;

interface ApnsConfig {
  keyId: string;
  teamId: string;
  key: string;
  bundleId: string;
  sandbox: boolean;
}

interface QueuedMessage {
  id: string;
  text: string;
  files: Array<{ data: Buffer; filename: string; mimeType?: string; size?: number }>;
  ts: string;
  conversationId?: string;
}

// Persist APNs device tokens across server restarts.
const TOKENS_FILE = path.join(process.cwd(), 'data', 'ios-apns-tokens.json');
const READ_RECEIPTS_FILE = path.join(process.cwd(), 'data', 'ios-read-receipts.json');
const readReceiptStore = new ReadReceiptStore();

/**
 * Per-instance health-history paths derived from `IosChannelConfig.healthHistoryDir`.
 * Lives INSIDE the analyzer agent's group folder so it is auto-mounted into the
 * container at /workspace/agent/health (no additional_mounts / allowlist needed
 * — mirrors how jarvis uses its folder). Host writes raw.jsonl (one daily row
 * per line); the analyzer reads it. requests/ holds fetch_health asks, serviced
 * by the HTTP poll endpoints below — no agent/LLM in the data-acquisition path.
 * See plan "Заход 2".
 */
interface HealthPaths {
  dir: string;
  raw: string;
  reqDir: string;
}

function resolveHealthPaths(healthHistoryDir?: string): HealthPaths {
  // Default preserves the original behavior — back-compat for existing installs
  // where the analyzer agent group is literally named "health-analyzer".
  const rel =
    healthHistoryDir && healthHistoryDir.length > 0
      ? healthHistoryDir
      : path.join('groups', 'health-analyzer', 'health');
  const dir = path.isAbsolute(rel) ? rel : path.join(process.cwd(), rel);
  return { dir, raw: path.join(dir, 'raw.jsonl'), reqDir: path.join(dir, 'requests') };
}

// Shared health-history ingestion — used by both the WS path (foreground) and the
// HTTP upload path (background). Appends/upserts rows and clears the serviced request.
function ingestHealthHistory(paths: HealthPaths, days: Array<Record<string, unknown>>, requestId?: string): void {
  appendHealthRows(paths, days);
  if (requestId) {
    try {
      fs.unlinkSync(path.join(paths.reqDir, `${requestId}.json`));
    } catch {
      // already gone
    }
  }
}

function appendHealthRows(paths: HealthPaths, rows: Array<Record<string, unknown>>): void {
  if (!rows.length) return;
  try {
    fs.mkdirSync(paths.dir, { recursive: true });
    // Upsert by date: one row per day (incoming wins), so re-fetches don't grow
    // the file with duplicates. Single writer (this adapter) → read-modify-write safe.
    const byDate = new Map<string, Record<string, unknown>>();
    try {
      for (const line of fs.readFileSync(paths.raw, 'utf8').split('\n')) {
        const s = line.trim();
        if (!s) continue;
        const r = JSON.parse(s) as Record<string, unknown>;
        if (typeof r.date === 'string') byDate.set(r.date, r);
      }
    } catch {
      // no existing file yet
    }
    for (const r of rows) {
      if (typeof r.date === 'string') byDate.set(r.date, r);
    }
    const out =
      [...byDate.keys()]
        .sort()
        .map((d) => JSON.stringify(byDate.get(d)))
        .join('\n') + '\n';
    const tmp = `${paths.raw}.tmp`;
    fs.writeFileSync(tmp, out);
    fs.renameSync(tmp, paths.raw);
  } catch {
    // best-effort; analyzer tolerates gaps
  }
}

function loadPersistedTokens(): Map<string, string> {
  try {
    const raw = fs.readFileSync(TOKENS_FILE, 'utf8');
    return new Map(Object.entries(JSON.parse(raw)));
  } catch {
    return new Map();
  }
}

function savePersistedTokens(tokens: Map<string, string>): void {
  const tmp = `${TOKENS_FILE}.tmp`;
  fs.writeFileSync(tmp, JSON.stringify(Object.fromEntries(tokens)));
  fs.renameSync(tmp, TOKENS_FILE);
}

(function loadReadReceipts() {
  try {
    const data = fs.readFileSync(READ_RECEIPTS_FILE, 'utf8');
    const arr = JSON.parse(data) as unknown[];
    if (Array.isArray(arr)) {
      readReceiptStore.hydrateObjects(arr);
    }
  } catch {}
})();

function persistReadReceipts(): void {
  try {
    const tmp = `${READ_RECEIPTS_FILE}.tmp`;
    fs.writeFileSync(tmp, JSON.stringify(readReceiptStore.all()), 'utf8');
    fs.renameSync(tmp, READ_RECEIPTS_FILE);
  } catch (e) {
    log(`persistReadReceipts failed: ${e instanceof Error ? e.message : String(e)}`);
  }
}

function getApnsJwt(cfg: ApnsConfig): string {
  const now = Math.floor(Date.now() / 1000);
  if (apnsJwt && now - apnsJwt.createdAt < 55 * 60) return apnsJwt.token;

  const header = Buffer.from(JSON.stringify({ alg: 'ES256', kid: cfg.keyId })).toString('base64url');
  const payload = Buffer.from(JSON.stringify({ iss: cfg.teamId, iat: now })).toString('base64url');
  const sign = createSign('SHA256');
  sign.update(`${header}.${payload}`);
  const sig = sign.sign(cfg.key, 'base64url');
  apnsJwt = { token: `${header}.${payload}.${sig}`, createdAt: now };
  return apnsJwt.token;
}

async function sendApnsPush(
  deviceToken: string,
  text: string,
  apns: ApnsConfig | null,
  conversationId?: string,
): Promise<{ status: number; body: string }> {
  if (!apns) return { status: 0, body: '' };
  const jwt = getApnsJwt(apns);
  const host = apns.sandbox ? 'api.sandbox.push.apple.com' : 'api.push.apple.com';
  const payload: Record<string, unknown> = { aps: { alert: { body: text }, sound: 'default' } };
  if (conversationId) payload.conversationId = conversationId;
  const body = JSON.stringify(payload);

  return await new Promise<{ status: number; body: string }>((resolve, reject) => {
    const client = http2.connect(`https://${host}`);
    // Always close the session, on success or any error path, so we never leak
    // an http2 connection on network failures.
    const fail = (e: unknown) => {
      client.close();
      reject(e instanceof Error ? e : new Error(String(e)));
    };
    client.once('error', fail);
    const req = client.request({
      ':method': 'POST',
      ':path': `/3/device/${deviceToken}`,
      ':scheme': 'https',
      ':authority': host,
      authorization: `bearer ${jwt}`,
      'apns-topic': apns.bundleId,
      'apns-push-type': 'alert',
      'content-type': 'application/json',
      'content-length': Buffer.byteLength(body),
    });
    req.setEncoding('utf8');
    req.once('error', fail); // without this a request-level error hangs the promise
    let status = 0;
    let resp = '';
    req.on('response', (h) => {
      status = h[':status'] as number;
    });
    req.on('data', (chunk) => {
      resp += chunk;
    });
    req.on('end', () => {
      client.close();
      resolve({ status, body: resp });
    });
    req.end(body);
  });
}

function isImageFile(filename: string, mimeType?: string): boolean {
  if (mimeType?.startsWith('image/')) return true;
  return /\.(png|jpe?g|gif|webp|heic|svg|bmp|tiff?)$/i.test(filename);
}

function deliverViaSock(ws: WebSocket, msg: QueuedMessage): void {
  if (ws.readyState !== WebSocket.OPEN) return;
  if (msg.text)
    ws.send(
      JSON.stringify({
        type: 'message',
        id: msg.id,
        text: msg.text,
        conversationId: msg.conversationId,
        timestamp: msg.ts,
      }),
    );
  for (const file of msg.files) {
    if (isImageFile(file.filename, file.mimeType)) {
      // Legacy image type — backwards compatible
      ws.send(
        JSON.stringify({
          type: 'image',
          id: randomUUID(),
          data: file.data.toString('base64'),
          filename: file.filename,
          conversationId: msg.conversationId,
          timestamp: msg.ts,
        }),
      );
    } else {
      // New file type — non-image attachments
      ws.send(
        JSON.stringify({
          type: 'file',
          id: randomUUID(),
          name: file.filename,
          size: file.size ?? file.data.length,
          mimeType: file.mimeType ?? 'application/octet-stream',
          data: file.data.toString('base64'),
          conversationId: msg.conversationId,
          timestamp: msg.ts,
        }),
      );
    }
  }
}

export interface IosWsHandlerState {
  wsClients: Map<string, Set<WebSocket>>;
  apnsTokens: Map<string, string>;
  pendingMessages: Map<string, QueuedMessage[]>;
  deliveredIds: Map<string, Set<string>>;
  lastTimezone: Map<string, string>;
  /** Per-device LRU of clientMessageIds we've already forwarded to the agent.
   *  Second-and-later occurrences emit ack only — never call onInbound twice. */
  processedClientMsgIds: Map<string, Set<string>>;
}

export function createIosWsHandler(opts: {
  token: string;
  store: ReadReceiptStore;
  cfg: {
    onInbound: (pid: string, tid: string | null, msg: Record<string, unknown>) => Promise<void>;
    onAction: (qid: string, bid: string, pid: string) => void;
  };
  state: IosWsHandlerState;
  persist: { receipts: () => void; tokens: () => void };
  deliverQueued: (ws: WebSocket, msg: QueuedMessage) => void;
}): (ws: WebSocket) => void {
  const { token, store, cfg, state, persist, deliverQueued } = opts;
  const { wsClients, apnsTokens, pendingMessages, deliveredIds, lastTimezone } = state;

  function recordDelivered(pid: string, id: string): void {
    let s = deliveredIds.get(pid);
    if (!s) deliveredIds.set(pid, (s = new Set()));
    if (s.size > 500) s.clear();
    s.add(id);
  }

  function isDuplicateClientMsgId(pid: string, cmid: string): boolean {
    let s = state.processedClientMsgIds.get(pid);
    if (!s) state.processedClientMsgIds.set(pid, (s = new Set()));
    if (s.has(cmid)) return true;
    if (s.size > 500) {
      // Simple LRU: blow the cache when it gets too big.
      s.clear();
    }
    s.add(cmid);
    return false;
  }

  function removeClient(pid: string, ws: WebSocket) {
    const s = wsClients.get(pid);
    if (!s) return;
    s.delete(ws);
    if (s.size === 0) {
      wsClients.delete(pid);
      lastTimezone.delete(pid);
    }
  }

  return (ws: WebSocket) => {
    let pid: string | null = null;
    let authed = false;
    let isAlive = true;
    ws.on('pong', () => {
      isAlive = true;
    });
    const ping = setInterval(() => {
      if (ws.readyState !== WebSocket.OPEN) return;
      if (!isAlive) {
        ws.terminate();
        return;
      }
      isAlive = false;
      ws.ping();
    }, 30_000);

    ws.on('message', async (data) => {
      let msg: Record<string, unknown>;
      try {
        msg = JSON.parse(data.toString());
      } catch {
        ws.close(1003);
        return;
      }

      if (!authed) {
        if (msg.type === 'auth' && msg.token === token && typeof msg.platformId === 'string') {
          authed = true;
          pid = msg.platformId;
          if (!wsClients.has(pid)) wsClients.set(pid, new Set());
          wsClients.get(pid)!.add(ws);
          if (typeof msg.apnsToken === 'string' && msg.apnsToken) {
            apnsTokens.set(pid, msg.apnsToken);
            persist.tokens();
          }
          ws.send(
            JSON.stringify({
              type: 'auth_ok',
              commands: BOT_COMMANDS.map((c) => ({ command: '/' + c.command, description: c.description })),
            }),
          );
          const pending = pendingMessages.get(pid);
          if (pending?.length) {
            pendingMessages.delete(pid);
            const seen = deliveredIds.get(pid);
            for (const p of pending) {
              if (seen?.has(p.id)) continue;
              deliverQueued(ws, p);
              recordDelivered(pid, p.id);
            }
          }
        } else {
          ws.close(4001);
        }
        return;
      }

      if (msg.type === 'apns_token' && typeof msg.token === 'string' && pid) {
        apnsTokens.set(pid, msg.token);
        persist.tokens();
      }

      if (msg.type === 'message_delivered' && pid && typeof msg.messageId === 'string') {
        store.record(pid, msg.messageId, 'delivered');
        persist.receipts();
      }

      if (msg.type === 'message_read' && pid && typeof msg.messageId === 'string') {
        store.record(pid, msg.messageId, 'read');
        persist.receipts();
      }

      if (msg.type === 'proactive' && pid && typeof msg.trigger === 'string') {
        const trigger = msg.trigger as string;
        const ts = typeof msg.ts === 'string' ? (msg.ts as string) : new Date().toISOString();
        const tz = typeof msg.tz === 'string' ? (msg.tz as string) : '';
        if (tz) lastTimezone.set(pid, tz);
        const payload = (msg.payload as Record<string, unknown> | undefined) ?? {};
        let body = `[proactive trigger=${trigger} ts=${ts}${tz ? ` tz=${tz}` : ''}]`;
        const lines = Object.entries(payload).map(([k, v]) => `${k}=${typeof v === 'string' ? v : JSON.stringify(v)}`);
        if (lines.length > 0) body += '\n' + lines.join(' ');
        body += '\n---';
        await cfg.onInbound(pid, null, {
          id: randomUUID(),
          kind: 'chat',
          content: { text: body, senderId: pid },
          timestamp: new Date().toISOString(),
        } as Record<string, unknown>);
        return;
      }

      if (msg.type === 'message' && typeof msg.text === 'string' && pid) {
        const cmid = typeof msg.clientMessageId === 'string' ? msg.clientMessageId : '';

        // Dedup BEFORE onInbound. Always ack so the client stops retrying.
        if (cmid && isDuplicateClientMsgId(pid, cmid)) {
          ws.send(JSON.stringify({ type: 'message_ack', clientMessageId: cmid }));
          return;
        }

        if (typeof msg.timezone === 'string' && msg.timezone) lastTimezone.set(pid, msg.timezone);
        const status = typeof msg.status === 'string' && msg.status ? `[status: ${msg.status}]\n` : '';
        const tid = typeof msg.conversationId === 'string' ? msg.conversationId : null;
        // Inline context block (location / health / device / nextEvent) — sent
        // alongside every user message so the agent always has timezone, location,
        // and next event in-band. The pull model still works on top.
        let inlineCtx = '';
        if (msg.context && typeof msg.context === 'object') {
          const ctxObj = msg.context as Record<string, unknown>;
          if (typeof ctxObj.timezone !== 'string' && msg.timezone) {
            ctxObj.timezone = msg.timezone as string;
          }
          try {
            const block = buildCtx(ctxObj);
            if (block) inlineCtx = `${block}\n`;
          } catch {
            // Bad context payload — skip, don't fail the message
          }
        }
        const content: Record<string, unknown> = { text: inlineCtx + status + msg.text, senderId: pid };
        if (Array.isArray(msg.attachments)) {
          const atts = (msg.attachments as Array<Record<string, unknown>>)
            .filter((a) => a && typeof a.data === 'string')
            .map((a) => {
              const out: Record<string, unknown> = {
                name: a.name,
                mimeType: a.mimeType,
                data: a.data,
                size: a.size,
              };
              if (typeof a.duration === 'number') out.duration = a.duration;
              return out;
            });
          if (atts.length > 0) content.attachments = atts;
        }
        await cfg.onInbound(pid, tid, {
          id: randomUUID(),
          kind: 'chat',
          content,
          timestamp: new Date().toISOString(),
        } as Record<string, unknown>);
        if (cmid) {
          ws.send(JSON.stringify({ type: 'message_ack', clientMessageId: cmid }));
        }
      }

      if (msg.type === 'context_response' && pid) {
        const tid = typeof msg.conversationId === 'string' ? msg.conversationId : null;
        const ctx = (msg.context as Record<string, unknown> | undefined) ?? {};
        if (typeof ctx.timezone !== 'string' && lastTimezone.has(pid)) ctx.timezone = lastTimezone.get(pid);
        const pendingReceipts = store.getPending(pid);
        if (pendingReceipts.length > 0) {
          ctx.readReceipts = pendingReceipts;
          store.markInjected(pendingReceipts);
          persist.receipts();
        }
        let block: string;
        try {
          block = buildCtx(ctx);
        } catch {
          block = '';
        }
        await cfg.onInbound(pid, tid, {
          id: randomUUID(),
          kind: 'chat',
          content: { text: block || '[iOS context — requested data unavailable]', senderId: pid },
          timestamp: new Date().toISOString(),
        } as Record<string, unknown>);
      }

      if (msg.type === 'feedback' && pid) {
        const positive = msg.value === true;
        const tid = typeof msg.conversationId === 'string' ? msg.conversationId : null;
        const rated = typeof msg.messageText === 'string' ? msg.messageText.slice(0, 800) : '';
        const quoted = rated
          ? `\n> ${rated.replace(/\n/g, '\n> ')}`
          : typeof msg.messageId === 'string'
            ? ` (id ${msg.messageId})`
            : '';
        await cfg.onInbound(pid, tid, {
          id: randomUUID(),
          kind: 'chat',
          content: {
            text: `[user feedback: ${positive ? '👍' : '👎'} on your previous message]${quoted}`,
            senderId: pid,
          },
          timestamp: new Date().toISOString(),
        } as Record<string, unknown>);
      }

      if (msg.type === 'action_response' && pid) {
        const tid = typeof msg.conversationId === 'string' ? msg.conversationId : null;
        const buttonLabel = typeof msg.buttonLabel === 'string' ? msg.buttonLabel : '';
        const buttonId = typeof msg.buttonId === 'string' ? msg.buttonId : '';
        const questionId = typeof msg.messageId === 'string' ? msg.messageId : '';
        if (questionId && buttonId) {
          cfg.onAction(questionId, buttonId, pid);
        } else {
          await cfg.onInbound(pid, tid, {
            id: randomUUID(),
            kind: 'chat',
            content: {
              text: `[user selected: "${buttonLabel}" (id: ${buttonId})]`,
              senderId: pid,
            },
            timestamp: new Date().toISOString(),
          } as Record<string, unknown>);
        }
      }

      if (msg.type === 'new_conversation' && pid) {
        // no-op — acknowledged but not routed
      }
    });

    ws.on('close', () => {
      clearInterval(ping);
      if (pid) removeClient(pid, ws);
    });
    ws.on('error', () => {
      clearInterval(ping);
      if (pid) removeClient(pid, ws);
    });
  };
}

/**
 * HTTP fallback handler for proactive triggers from iOS.
 *
 * When the dispatcher fires (geofence / HK / calendar) and the WS can't
 * reconnect in time, the iOS app POSTs to /ios/proactive with the same
 * envelope shape as the WS `proactive` message. The agent-facing inbound
 * message is identical to the WS path.
 *
 * Standalone factory — does not handle the other /ios/* routes (those live
 * inline in the adapter setup). Tests use this directly without spinning up
 * the full adapter.
 */
export function createIosHttpHandler(opts: {
  token: string;
  cfg: { onInbound: (pid: string, tid: string | null, msg: Record<string, unknown>) => Promise<void> };
  state: IosWsHandlerState;
}): (req: import('node:http').IncomingMessage, res: import('node:http').ServerResponse) => Promise<void> {
  return async (req, res) => {
    if (req.method === 'POST' && req.url === '/ios/proactive') {
      const auth = req.headers['authorization'];
      if (auth !== `Bearer ${opts.token}`) {
        res.statusCode = 401;
        res.end();
        return;
      }
      const chunks: Buffer[] = [];
      for await (const c of req) chunks.push(c as Buffer);
      let body: Record<string, unknown>;
      try {
        body = JSON.parse(Buffer.concat(chunks).toString('utf8')) as Record<string, unknown>;
      } catch {
        res.statusCode = 400;
        res.end();
        return;
      }
      const pid = typeof body.platformId === 'string' ? body.platformId : null;
      const trigger = typeof body.trigger === 'string' ? body.trigger : null;
      if (!pid || !trigger) {
        res.statusCode = 400;
        res.end();
        return;
      }
      const payload = body.payload && typeof body.payload === 'object' ? (body.payload as Record<string, unknown>) : {};
      const ts = typeof body.ts === 'string' ? body.ts : new Date().toISOString();
      const tz = typeof body.tz === 'string' ? body.tz : '';
      let text = `[proactive trigger=${trigger} ts=${ts}${tz ? ` tz=${tz}` : ''}]`;
      const lines = Object.entries(payload).map(([k, v]) => `${k}=${typeof v === 'string' ? v : JSON.stringify(v)}`);
      if (lines.length > 0) text += '\n' + lines.join(' ');
      text += '\n---';
      await opts.cfg.onInbound(pid, null, {
        id: randomUUID(),
        kind: 'chat',
        content: { text, senderId: pid },
        timestamp: new Date().toISOString(),
      } as Record<string, unknown>);
      res.statusCode = 204;
      res.end();
      return;
    }
    res.statusCode = 404;
    res.end();
  };
}

function createIOSAdapter(): ChannelAdapter | null {
  const env = readEnvFile([
    'IOS_APP_TOKEN',
    'IOS_APP_PORT',
    'IOS_APNS_KEY_ID',
    'IOS_APNS_TEAM_ID',
    'IOS_APNS_BUNDLE_ID',
    'IOS_APNS_KEY',
    'IOS_APNS_ENV',
    'IOS_HEALTH_HISTORY_DIR',
  ]);
  const token = env.IOS_APP_TOKEN;
  if (!token) return null;
  const port = parseInt(env.IOS_APP_PORT ?? '3001', 10);
  // Where iOS health-history JSONL ingestion lands. Reads (analyzer's fetch
  // requests) and writes (daily aggregates) both happen here. Defaults to
  // `groups/health-analyzer/health/` for back-compat — override with
  // `IOS_HEALTH_HISTORY_DIR` when the analyzer agent lives under a different
  // group name. Absolute paths supported; relative paths resolve against cwd.
  const healthPaths = resolveHealthPaths(env.IOS_HEALTH_HISTORY_DIR);

  const apnsCfg: ApnsConfig | null =
    env.IOS_APNS_KEY_ID && env.IOS_APNS_TEAM_ID && env.IOS_APNS_KEY && env.IOS_APNS_BUNDLE_ID
      ? {
          keyId: env.IOS_APNS_KEY_ID,
          teamId: env.IOS_APNS_TEAM_ID,
          key: env.IOS_APNS_KEY,
          bundleId: env.IOS_APNS_BUNDLE_ID,
          sandbox: env.IOS_APNS_ENV === 'sandbox',
        }
      : null;

  const wsClients = new Map<string, Set<WebSocket>>();
  const apnsTokens = loadPersistedTokens();
  const pendingMessages = new Map<string, QueuedMessage[]>();
  // Last-known IANA timezone per device — used to format dates in pulled context.
  const lastTimezone = new Map<string, string>();
  // Bounded record of delivered message ids per device, so re-flushing the
  // offline queue on reconnect can't deliver the same message twice.
  const deliveredIds = new Map<string, Set<string>>();
  let cfg: ChannelSetup | null = null;
  let httpServer: http.Server | null = null;
  let wss: WebSocketServer | null = null;
  // Health fetch requests are drained by the app over HTTP (GET /ios/health/requests
  // → POST /ios/health/upload). No server-side push/watcher needed — the app polls.

  function deliverTextAndFiles(
    platformId: string,
    threadId: string | null,
    text: string,
    files: Array<{ data: Buffer; filename: string; mimeType?: string; size?: number }>,
  ): string {
    const id = randomUUID();
    const ts = new Date().toISOString();
    const queued: QueuedMessage = { id, text, files, ts, conversationId: threadId ?? undefined };

    const set = wsClients.get(platformId);
    if (set && set.size > 0) {
      set.forEach((ws) => deliverViaSock(ws, queued));
      // Record delivered inline (mirrors recordDelivered in createIosWsHandler)
      let ds = deliveredIds.get(platformId);
      if (!ds) deliveredIds.set(platformId, (ds = new Set()));
      if (ds.size > 500) ds.clear();
      ds.add(id);
    } else {
      // Cap the offline queue so a long-offline device can't grow it unbounded
      // (base64 file payloads especially). Drop the oldest on overflow.
      const queue = [...(pendingMessages.get(platformId) ?? []), queued];
      if (queue.length > MAX_PENDING_PER_DEVICE) {
        const dropped = queue.length - MAX_PENDING_PER_DEVICE;
        queue.splice(0, dropped);
        log(`pendingMessages overflow for ${platformId} — dropped ${dropped} oldest`);
      }
      pendingMessages.set(platformId, queue);
      const apnsToken = apnsTokens.get(platformId);
      if (apnsToken) {
        const preview = text ? text.slice(0, 80) : (files[0]?.filename ?? 'Новое сообщение');
        sendApnsPush(apnsToken, preview, apnsCfg, queued.conversationId)
          .then(({ status, body }) => {
            if (status === 200 || status === 0) return;
            log(`APNs ${status} for ${platformId}: ${body}`);
            // 410 = unregistered, 400 = bad device token → drop it so we stop retrying.
            if (status === 410 || status === 400) {
              apnsTokens.delete(platformId);
              savePersistedTokens(apnsTokens);
              log(`Dropped dead APNs token for ${platformId}`);
            }
          })
          .catch((e) => log(`APNs send error for ${platformId}: ${e instanceof Error ? e.message : String(e)}`));
      }
    }
    return id;
  }

  return {
    name: 'ios-app',
    channelType: 'ios-app',
    supportsThreads: true,

    async setup(config: ChannelSetup) {
      cfg = config;

      httpServer = http.createServer((req, res) => {
        if (req.method === 'GET' && req.url === '/ios/health') {
          res.writeHead(200, { 'Content-Type': 'application/json' }).end('{"ok":true}');
          return;
        }
        // Pending fetch requests — the app polls this (on foreground + on HealthKit
        // background-delivery wake) and services each over HTTP. No APNs needed:
        // the app pulls, the server never has to wake it. Plan "Заход 3" (HTTP-poll).
        if (req.method === 'GET' && req.url === '/ios/health/requests') {
          if ((req.headers.authorization ?? '') !== `Bearer ${token}`) {
            res.writeHead(401).end();
            return;
          }
          let pending: Array<Record<string, unknown>> = [];
          try {
            pending = fs
              .readdirSync(healthPaths.reqDir)
              .filter((f) => f.endsWith('.json'))
              .map((f) => {
                const r = JSON.parse(fs.readFileSync(path.join(healthPaths.reqDir, f), 'utf8'));
                return { requestId: f.replace(/\.json$/, ''), from: r.from, to: r.to };
              });
          } catch {
            pending = [];
          }
          res.writeHead(200, { 'Content-Type': 'application/json' }).end(JSON.stringify({ requests: pending }));
          return;
        }
        // Background health upload — the app (foreground or woken by HealthKit
        // background delivery) POSTs daily aggregates here. WS stays chat-only.
        if (req.method === 'POST' && req.url === '/ios/health/upload') {
          const auth = req.headers.authorization ?? '';
          if (auth !== `Bearer ${token}`) {
            res.writeHead(401).end();
            return;
          }
          let raw = '';
          req.setEncoding('utf8');
          req.on('data', (c) => {
            raw += c;
            if (raw.length > 2_000_000) req.destroy(); // guard against oversized uploads
          });
          req.on('end', () => {
            try {
              const obj = JSON.parse(raw) as { requestId?: string; days?: Array<Record<string, unknown>> };
              const days = Array.isArray(obj.days) ? obj.days : [];
              ingestHealthHistory(healthPaths, days, typeof obj.requestId === 'string' ? obj.requestId : undefined);
              log(`health_history (http): +${days.length} day(s)${obj.requestId ? ` (req ${obj.requestId})` : ''}`);
              res.writeHead(200, { 'Content-Type': 'application/json' }).end('{"ok":true}');
            } catch {
              res.writeHead(400).end();
            }
          });
          return;
        }
        res.writeHead(404).end();
      });

      wss = new WebSocketServer({ server: httpServer });

      const handlerState: IosWsHandlerState = {
        wsClients,
        apnsTokens,
        pendingMessages,
        deliveredIds,
        lastTimezone,
        processedClientMsgIds: new Map(),
      };

      wss.on(
        'connection',
        createIosWsHandler({
          token,
          store: readReceiptStore,
          cfg: {
            onInbound: async (pid, tid, msg) =>
              cfg!.onInbound(pid, tid, msg as unknown as Parameters<ChannelSetup['onInbound']>[2]),
            onAction: (qid, bid, pid) => cfg!.onAction(qid, bid, pid),
          },
          state: handlerState,
          persist: { receipts: persistReadReceipts, tokens: () => savePersistedTokens(apnsTokens) },
          deliverQueued: deliverViaSock,
        }),
      );

      await new Promise<void>((ok, fail) => httpServer!.listen(port, '0.0.0.0', ok).on('error', fail));

      // Ensure the request queue dir exists; the app drains it via HTTP poll.
      try {
        fs.mkdirSync(healthPaths.reqDir, { recursive: true });
      } catch {
        // best-effort
      }
    },

    async teardown() {
      wss?.close();
      await new Promise<void>((r) => httpServer?.close(() => r()));
    },

    isConnected() {
      return httpServer?.listening ?? false;
    },

    async deliver(platformId, threadId, message) {
      const c = message.content as Record<string, unknown>;
      const text = (c.markdown ?? c.text ?? '') as string;
      const files = (message.files ?? []) as Array<{
        data: Buffer;
        filename: string;
        mimeType?: string;
        size?: number;
      }>;
      const contentType = c.type as string | undefined;

      // Context pull request — forward to a live socket so the app can reply
      // with a context_response. Hidden from the user. If the device is offline,
      // tell the agent so it doesn't wait forever for a follow-up.
      if (contentType === 'context_request') {
        const requestId = (c.requestId as string) ?? randomUUID();
        const payload = JSON.stringify({
          type: 'context_request',
          requestId,
          fields: (c.fields as string[]) ?? [],
        });
        const set = wsClients.get(platformId);
        const live = set ? [...set].filter((ws) => ws.readyState === WebSocket.OPEN) : [];
        if (live.length > 0) {
          live.forEach((ws) => ws.send(payload));
          log(`context_request ${requestId} → ${platformId} (${live.length} socket)`);
        } else {
          log(`context_request ${requestId} → ${platformId} offline`);
          await cfg!.onInbound(platformId, threadId, {
            id: randomUUID(),
            kind: 'chat',
            content: { text: '[iOS context unavailable — device offline]', senderId: platformId },
            timestamp: new Date().toISOString(),
          });
        }
        return requestId;
      }

      // Handle structured message types from agent
      if (contentType === 'ask_question' && c.questionId) {
        // Send as action message with buttons
        const title = (c.title ?? '') as string;
        const options = (c.options ?? []) as Array<Record<string, unknown>>;
        const buttons = options.map((opt, i) => ({
          id: (opt.id as string) ?? `opt_${i}`,
          label: (opt.label ?? opt.text ?? '') as string,
          style: (opt.style as string) ?? 'primary',
        }));

        const payload = JSON.stringify({
          type: 'action',
          id: (c.questionId as string) ?? randomUUID(),
          text: title,
          buttons,
          conversationId: threadId ?? undefined,
          timestamp: new Date().toISOString(),
        });

        const set = wsClients.get(platformId);
        if (set && set.size > 0) {
          set.forEach((ws) => {
            if (ws.readyState === WebSocket.OPEN) ws.send(payload);
          });
        }
        // Also deliver text version if present for offline/push
        if (text) {
          return deliverTextAndFiles(platformId, threadId, text, files);
        }
        return c.questionId as string;
      }

      // Status banner (renders as ──── icon text ──── divider on iOS)
      if (contentType === 'status') {
        const payload = JSON.stringify({
          type: 'status',
          id: randomUUID(),
          text: (c.text ?? '') as string,
          level: (c.level ?? 'info') as string,
          kind: (c.kind ?? 'system') as string,
          conversationId: threadId ?? undefined,
          timestamp: new Date().toISOString(),
        });
        const set = wsClients.get(platformId);
        if (set && set.size > 0) {
          set.forEach((ws) => {
            if (ws.readyState === WebSocket.OPEN) ws.send(payload);
          });
        }
        return randomUUID();
      }

      if (!text && files.length === 0) return undefined;
      return deliverTextAndFiles(platformId, threadId, text, files);
    },
  };
}

function buildCtx(ctx: Record<string, unknown>): string {
  const lines: string[] = [];
  if (ctx.location) {
    const l = ctx.location as Record<string, unknown>;
    lines.push(`📍 ${l.city ?? ''} (${l.lat}, ${l.lon})`);
  }
  if (ctx.health) {
    const h = ctx.health as Record<string, unknown>;
    const p: string[] = [];
    if (h.steps) p.push(`Steps: ${h.steps}`);
    if (h.heartRate) p.push(`HR: ${h.heartRate} bpm`);
    if (h.activeEnergy) p.push(`Active: ${h.activeEnergy} kcal`);
    if (h.sleepHours) p.push(`Sleep: ${h.sleepHours}h`);
    if (h.restingHeartRate) p.push(`RHR: ${h.restingHeartRate} bpm`);
    if (h.exerciseMinutes) p.push(`Exercise: ${h.exerciseMinutes} min`);
    if (p.length) lines.push(`🏃 ${p.join(' | ')}`);
  }
  if (ctx.device) {
    const d = ctx.device as Record<string, unknown>;
    const p: string[] = [];
    if (d.battery !== undefined) p.push(`Battery: ${d.battery}%`);
    if (d.lowPower) p.push('Low Power');
    if (d.network) p.push(`Net: ${d.network}`);
    if (p.length) lines.push(`📱 ${p.join(' | ')}`);
  }
  if (ctx.nextEvent) {
    const e = ctx.nextEvent as Record<string, unknown>;
    if (e.title && e.start) {
      const when = new Date(e.start as string).toLocaleString('ru-RU', {
        timeZone: (ctx.timezone as string | undefined) ?? 'Europe/Moscow',
        hour: '2-digit',
        minute: '2-digit',
        day: 'numeric',
        month: 'short',
      });
      lines.push(`📅 ${e.title} — ${when}`);
    }
  }
  if (Array.isArray(ctx.readReceipts) && ctx.readReceipts.length > 0) {
    const tz = (ctx.timezone as string | undefined) ?? 'Europe/Moscow';
    const fmtTime = (iso: string) =>
      new Date(iso).toLocaleTimeString('ru-RU', { timeZone: tz, hour: '2-digit', minute: '2-digit' });
    lines.push('[read receipts]');
    for (const r of ctx.readReceipts as Array<{ messageId: string; deliveredAt: string; readAt?: string }>) {
      const short = r.messageId.slice(0, 8);
      const d = `delivered ${fmtTime(r.deliveredAt)}`;
      const rd = r.readAt ? `, read ${fmtTime(r.readAt)}` : '';
      lines.push(`msg ${short} ${d}${rd}`);
    }
  }
  if (!lines.length && !ctx.status) return '';

  // Use device-provided timestamp and timezone if available; fall back to server time in Moscow tz.
  const tz = (ctx.timezone as string | undefined) ?? 'Europe/Moscow';
  const tsOpts: Intl.DateTimeFormatOptions = { timeZone: tz, timeZoneName: 'longOffset' };
  const ts = ctx.timestamp
    ? new Date(ctx.timestamp as string).toLocaleString('ru-RU', tsOpts)
    : new Date().toLocaleString('ru-RU', tsOpts);

  const statusSuffix = ctx.status ? ` ${ctx.status}` : '';
  return `[iOS Context — ${ts}${statusSuffix}]\n${lines.join('\n')}${lines.length ? '\n' : ''}---\n`;
}

registerChannelAdapter('ios-app', { factory: createIOSAdapter });
