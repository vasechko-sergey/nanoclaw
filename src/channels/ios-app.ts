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

// Health time-series store for the autonomous analyzer (Greg). Lives INSIDE Greg's
// group folder so it is auto-mounted into his container at /workspace/agent/health
// (no additional_mounts / allowlist needed — mirrors how jarvis uses its folder).
// Host writes raw.jsonl (one daily row per line); Greg reads it. requests/ holds
// Greg's fetch_health asks, serviced by the watcher in setup() — no agent/LLM in
// the data-acquisition path. See plan "Заход 2".
const HEALTH_DIR = path.join(process.cwd(), 'groups', 'health-analyzer', 'health');
const HEALTH_RAW = path.join(HEALTH_DIR, 'raw.jsonl');
const HEALTH_REQ_DIR = path.join(HEALTH_DIR, 'requests');

// Shared health-history ingestion — used by both the WS path (foreground) and the
// HTTP upload path (background). Appends/upserts rows and clears the serviced request.
function ingestHealthHistory(days: Array<Record<string, unknown>>, requestId?: string): void {
  appendHealthRows(days);
  if (requestId) {
    try {
      fs.unlinkSync(path.join(HEALTH_REQ_DIR, `${requestId}.json`));
    } catch {
      // already gone
    }
  }
}

function appendHealthRows(rows: Array<Record<string, unknown>>): void {
  if (!rows.length) return;
  try {
    fs.mkdirSync(HEALTH_DIR, { recursive: true });
    // Upsert by date: one row per day (incoming wins), so re-fetches don't grow
    // the file with duplicates. Single writer (this adapter) → read-modify-write safe.
    const byDate = new Map<string, Record<string, unknown>>();
    try {
      for (const line of fs.readFileSync(HEALTH_RAW, 'utf8').split('\n')) {
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
    const tmp = `${HEALTH_RAW}.tmp`;
    fs.writeFileSync(tmp, out);
    fs.renameSync(tmp, HEALTH_RAW);
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

// Silent (content-available) push — wakes the app in the background to run a task
// (e.g. fetch_health) and upload over HTTP. No alert/sound. Used when no WS socket
// is connected. iOS throttles these; force-quit suppresses them entirely.
async function sendApnsSilentPush(
  deviceToken: string,
  data: Record<string, unknown>,
  apns: ApnsConfig | null,
): Promise<{ status: number; body: string }> {
  if (!apns) return { status: 0, body: '' };
  const jwt = getApnsJwt(apns);
  const host = apns.sandbox ? 'api.sandbox.push.apple.com' : 'api.push.apple.com';
  const body = JSON.stringify({ aps: { 'content-available': 1 }, ...data });

  return await new Promise<{ status: number; body: string }>((resolve, reject) => {
    const client = http2.connect(`https://${host}`);
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
      'apns-push-type': 'background',
      'apns-priority': '5',
      'content-type': 'application/json',
      'content-length': Buffer.byteLength(body),
    });
    req.setEncoding('utf8');
    req.once('error', fail);
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

function createIOSAdapter(): ChannelAdapter | null {
  const env = readEnvFile([
    'IOS_APP_TOKEN',
    'IOS_APP_PORT',
    'IOS_APNS_KEY_ID',
    'IOS_APNS_TEAM_ID',
    'IOS_APNS_BUNDLE_ID',
    'IOS_APNS_KEY',
    'IOS_APNS_ENV',
  ]);
  const token = env.IOS_APP_TOKEN;
  if (!token) return null;
  const port = parseInt(env.IOS_APP_PORT ?? '3001', 10);

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
  function recordDelivered(pid: string, id: string): void {
    let s = deliveredIds.get(pid);
    if (!s) deliveredIds.set(pid, (s = new Set()));
    if (s.size > 500) s.clear();
    s.add(id);
  }
  let cfg: ChannelSetup | null = null;
  let httpServer: http.Server | null = null;
  let wss: WebSocketServer | null = null;
  let healthWatcher: ReturnType<typeof setInterval> | null = null;

  // Service the analyzer's fetch_health asks: send a control to connected clients.
  // Retries every cycle until the device answers (deletes the request) — survives
  // app offline (plan P2). lastSentAt throttles resends while waiting.
  const healthReqSentAt = new Map<string, number>();
  function serviceHealthRequests(): void {
    let files: string[];
    try {
      files = fs.readdirSync(HEALTH_REQ_DIR).filter((f) => f.endsWith('.json'));
    } catch {
      return; // dir not created yet
    }
    for (const f of files) {
      const reqId = f.replace(/\.json$/, '');
      if (Date.now() - (healthReqSentAt.get(reqId) ?? 0) < 60_000) continue;
      let req: { from?: string; to?: string; metrics?: string[]; platformId?: string };
      try {
        req = JSON.parse(fs.readFileSync(path.join(HEALTH_REQ_DIR, f), 'utf8'));
      } catch {
        continue;
      }
      const wsTargets = req.platformId ? [req.platformId] : [...wsClients.keys()];
      let sent = false;
      const payload = JSON.stringify({
        type: 'fetch_health',
        requestId: reqId,
        from: req.from,
        to: req.to,
        metrics: req.metrics,
      });
      for (const tpid of wsTargets) {
        wsClients.get(tpid)?.forEach((w) => {
          if (w.readyState === WebSocket.OPEN) {
            w.send(payload);
            sent = true;
          }
        });
      }
      // Always also wake the app via silent push. A backgrounded app may keep a WS
      // socket that looks "open" server-side but can't service the receive loop, so
      // the WS path alone is unreliable in background. Silent push fires foreground
      // and background; the HTTP upload is idempotent (upsert by date). Plan "Заход 3" B.
      const pushTargets = req.platformId ? [req.platformId] : [...apnsTokens.keys()];
      for (const tpid of pushTargets) {
        const apnsToken = apnsTokens.get(tpid);
        if (!apnsToken) continue;
        sendApnsSilentPush(apnsToken, { fetch: { requestId: reqId, from: req.from, to: req.to } }, apnsCfg)
          .then(({ status }) => {
            if (status && status !== 200) log(`silent push ${status} for ${tpid} (req ${reqId})`);
          })
          .catch((e) => log(`silent push error for ${tpid}: ${e instanceof Error ? e.message : String(e)}`));
        sent = true;
      }
      if (sent) healthReqSentAt.set(reqId, Date.now());
    }
  }

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
      recordDelivered(platformId, id);
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

  function removeClient(pid: string, ws: WebSocket) {
    const s = wsClients.get(pid);
    if (!s) return;
    s.delete(ws);
    if (s.size === 0) {
      wsClients.delete(pid);
      lastTimezone.delete(pid);
      // deliveredIds kept on purpose — needed to dedup re-flush on reconnect.
    }
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
        // Background health upload — the app, woken by silent push or HealthKit
        // background delivery, POSTs daily aggregates here (WS may be offline).
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
              ingestHealthHistory(days, typeof obj.requestId === 'string' ? obj.requestId : undefined);
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

      wss.on('connection', (ws) => {
        let pid: string | null = null;
        let authed = false;
        let isAlive = true;
        ws.on('pong', () => {
          isAlive = true;
        });
        const ping = setInterval(() => {
          if (ws.readyState !== WebSocket.OPEN) return;
          if (!isAlive) {
            log(`No pong from ${pid ?? 'unauthed'} — terminating dead socket`);
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
            log('Malformed JSON from client — closing');
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
                savePersistedTokens(apnsTokens);
              }
              ws.send(
                JSON.stringify({
                  type: 'auth_ok',
                  commands: BOT_COMMANDS.map((c) => ({ command: '/' + c.command, description: c.description })),
                }),
              );

              // Flush messages queued while app was closed. Clear the queue first
              // so a concurrent delivery can't double-send, and skip any id already
              // delivered to this device.
              const pending = pendingMessages.get(pid);
              if (pending?.length) {
                pendingMessages.delete(pid);
                const seen = deliveredIds.get(pid);
                for (const p of pending) {
                  if (seen?.has(p.id)) continue;
                  deliverViaSock(ws, p);
                  recordDelivered(pid, p.id);
                }
              }
            } else {
              log('Auth failed (bad token or missing platformId) — closing');
              ws.close(4001);
            }
            return;
          }

          if (msg.type === 'apns_token' && typeof msg.token === 'string' && pid) {
            apnsTokens.set(pid, msg.token);
            savePersistedTokens(apnsTokens);
          }

          if (msg.type === 'message' && typeof msg.text === 'string' && pid) {
            // Context is now pull-based (request_context tool) — the app no longer
            // pushes heavy context per message. Only the timezone rides along (cheap)
            // and is cached for formatting dates in pulled context.
            if (typeof msg.timezone === 'string' && msg.timezone) lastTimezone.set(pid, msg.timezone);
            const status = typeof msg.status === 'string' && msg.status ? `[status: ${msg.status}]\n` : '';
            const tid = typeof msg.conversationId === 'string' ? msg.conversationId : null;
            await cfg!.onInbound(pid, tid, {
              id: randomUUID(),
              kind: 'chat',
              content: { text: status + msg.text, senderId: pid },
              timestamp: new Date().toISOString(),
            });
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
            await cfg!.onInbound(pid, tid, {
              id: randomUUID(),
              kind: 'chat',
              content: {
                text: `[user feedback: ${positive ? '👍' : '👎'} on your previous message]${quoted}`,
                senderId: pid,
              },
              timestamp: new Date().toISOString(),
            });
          }

          // Context response — reply to a request_context pull. Technical, hidden
          // from the user; feeds the requested context back to the agent as a
          // follow-up message that wakes a new turn.
          if (msg.type === 'context_response' && pid) {
            const tid = typeof msg.conversationId === 'string' ? msg.conversationId : null;
            const ctx = (msg.context as Record<string, unknown> | undefined) ?? {};
            if (typeof ctx.timezone !== 'string' && lastTimezone.has(pid)) ctx.timezone = lastTimezone.get(pid);
            let block: string;
            try {
              block = buildCtx(ctx);
            } catch (e) {
              log(`buildCtx failed for ${pid}: ${e instanceof Error ? e.message : String(e)}`);
              block = '';
            }
            await cfg!.onInbound(pid, tid, {
              id: randomUUID(),
              kind: 'chat',
              content: {
                text: block || '[iOS context — requested data unavailable]',
                senderId: pid,
              },
              timestamp: new Date().toISOString(),
            });
          }

          // Health history — reply to a fetch_health pull. Technical: append daily
          // rows to the raw store and clear the serviced request. Not routed to any agent.
          if (msg.type === 'health_history') {
            const days = Array.isArray(msg.days) ? (msg.days as Array<Record<string, unknown>>) : [];
            const reqId = typeof msg.requestId === 'string' ? msg.requestId : undefined;
            ingestHealthHistory(days, reqId);
            log(`health_history (ws): +${days.length} day(s)${reqId ? ` (req ${reqId})` : ''}`);
            return;
          }

          // Action response — user tapped a button on an action message.
          // For ask_question/approval cards the questionId (the action message id)
          // is present → resolve the pending_questions/approval row structurally via
          // onAction. Only fall back to a free-text inbound when there's no questionId.
          if (msg.type === 'action_response' && pid) {
            const tid = typeof msg.conversationId === 'string' ? msg.conversationId : null;
            const buttonLabel = typeof msg.buttonLabel === 'string' ? msg.buttonLabel : '';
            const buttonId = typeof msg.buttonId === 'string' ? msg.buttonId : '';
            const questionId = typeof msg.messageId === 'string' ? msg.messageId : '';
            if (questionId && buttonId) {
              cfg!.onAction(questionId, buttonId, pid);
            } else {
              await cfg!.onInbound(pid, tid, {
                id: randomUUID(),
                kind: 'chat',
                content: {
                  text: `[user selected: "${buttonLabel}" (id: ${buttonId})]`,
                  senderId: pid,
                },
                timestamp: new Date().toISOString(),
              });
            }
          }

          // New conversation — acknowledge (currently logged, not routed)
          if (msg.type === 'new_conversation' && pid) {
            // Acknowledge — the agent doesn't need to know about conversation switches
            // but we could use this for session tracking in the future.
          }
        });

        ws.on('close', () => {
          clearInterval(ping);
          if (pid) removeClient(pid, ws);
        });
        ws.on('error', (e) => {
          log(`WebSocket error (${pid ?? 'unauthed'}): ${e instanceof Error ? e.message : String(e)}`);
          clearInterval(ping);
          if (pid) removeClient(pid, ws);
        });
      });

      await new Promise<void>((ok, fail) => httpServer!.listen(port, '0.0.0.0', ok).on('error', fail));

      // Health-request watcher: service the analyzer's fetch_health asks.
      try {
        fs.mkdirSync(HEALTH_REQ_DIR, { recursive: true });
      } catch {
        // best-effort
      }
      healthWatcher = setInterval(serviceHealthRequests, 10_000);
    },

    async teardown() {
      if (healthWatcher) clearInterval(healthWatcher);
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
