// HTTP request handler for the v2 ios-app adapter's non-WS surface.
//
// Routes:
//   GET  /ios/health             — liveness echo (unauthenticated; matches
//                                    the legacy adapter so existing health
//                                    probes don't break).
//   GET  /ios/health/requests?platformId=X
//                                — list pending health-fetch requests for
//                                    a device. Bearer auth.
//   POST /ios/health/upload      — ingest daily aggregates + clear the
//                                    serviced request. Bearer auth.
//   POST /ios/proactive          — HTTP fallback for proactive triggers
//                                    when the WS is offline. Bearer auth.
//                                    Routes by the token's platform_id; any
//                                    body.platformId is ignored (no cross-
//                                    person injection).
//
// Extracted into a standalone factory so tests can mount it on a stub
// `http.Server` without spinning up the full adapter (which requires env
// vars + a live ws server).
import http from 'node:http';
import { randomUUID } from 'node:crypto';
import { existsSync, readdirSync, readFileSync } from 'node:fs';
import { join } from 'node:path';

import type { ChannelSetup } from '../../adapter.js';
import { HealthUploadBody } from '../../../../shared/ios-app-protocol/index.js';
import type { HealthUploadDay } from '../../../../shared/ios-app-protocol/index.js';
import { sickDayCheck } from '../../../modules/health-trigger/sick-day.js';
import { readEnvFile } from '../../../env.js';
import { userMemoryRoot, userGlobalRoot } from '../../../user-memory.js';
import { appendHealthHistory } from './health-ingest.js';
import { openHealthDb, readHealthDays } from './health-db.js';
import type { HealthRequestsStore } from './health-requests-store.js';
import { parseProfile } from './profiles.js';

function loadAllHealthRows(agentRoot: string): HealthUploadDay[] {
  const dbPath = join(agentRoot, 'health', 'health.db');
  if (!existsSync(dbPath)) return [];
  const db = openHealthDb(dbPath);
  try {
    return readHealthDays(db); // already sorted oldest→newest by date
  } finally {
    db.close();
  }
}

export interface HttpHandlerDeps {
  /**
   * Resolve a raw bearer token to its identity, or null if unknown. Identity
   * for every protected route comes from here — NEVER from `body.platformId`
   * or a query param (those are client-supplied and may not match the server's
   * platform_id).
   */
  resolveToken: (rawToken: string) => { platform_id: string; person_key: string } | null;
  healthRequestsStore: HealthRequestsStore;
  /**
   * Folder name of the agent that owns health data (e.g. `greg`). Health
   * uploads land under `data/user-memory/<person>/<healthAgentFolder>`.
   */
  healthAgentFolder: string;
  /** Where proactive HTTP fallbacks go — same hook as the WS path. */
  getChannelSetup: () => ChannelSetup | null;
  log: (msg: string, ctx?: Record<string, unknown>) => void;
  logWarn: (msg: string, ctx?: Record<string, unknown>) => void;
}

export function createIosHttpHandler(deps: HttpHandlerDeps) {
  const { resolveToken, healthRequestsStore, healthAgentFolder, getChannelSetup, log, logWarn } = deps;

  const AGENT_META: Record<string, { title: string; icon: string }> = {
    greg: { title: 'Здоровье · Greg', icon: '🩺' },
    gordon: { title: 'Питание · Gordon', icon: '🍽' },
    payne: { title: 'Тренировки · Payne', icon: '🏋' },
    scrooge: { title: 'Финансы · Scrooge', icon: '💰' },
    jarvis: { title: 'Фокус · Jarvis', icon: '🧭' },
  };
  const AGENT_ORDER = ['greg', 'gordon', 'payne', 'scrooge', 'jarvis'];

  const authIdentity = (req: http.IncomingMessage): { platform_id: string; person_key: string } | null => {
    const auth = req.headers.authorization ?? '';
    if (!auth.startsWith('Bearer ')) return null;
    return resolveToken(auth.slice('Bearer '.length));
  };

  const readBody = (req: http.IncomingMessage): Promise<string> =>
    new Promise((resolve, reject) => {
      let raw = '';
      req.setEncoding('utf8');
      req.on('data', (c) => {
        raw += c;
        // Guard: cap at ~2 MB so a misbehaving client can't OOM the host.
        if (raw.length > 2_000_000) {
          reject(new Error('body too large'));
          req.destroy();
        }
      });
      req.on('end', () => resolve(raw));
      req.on('error', reject);
    });

  return (req: http.IncomingMessage, res: http.ServerResponse): void => {
    const url = new URL(req.url ?? '/', 'http://localhost');

    // Liveness — unauthenticated (load balancers, monitors, etc.). This
    // matches the legacy adapter's behavior.
    if (req.method === 'GET' && url.pathname === '/ios/health') {
      res.writeHead(200, { 'Content-Type': 'application/json' }).end('{"ok":true}');
      return;
    }

    if (req.method === 'GET' && url.pathname === '/ios/health/requests') {
      const id = authIdentity(req);
      if (!id) {
        res.writeHead(401, { 'Content-Type': 'application/json' }).end('{"error":"unauthorized"}');
        return;
      }
      // Device is identified by the token, not the query param. Ignore any
      // ?platformId= the client sends — the token's platform_id is canonical.
      const rows = healthRequestsStore.listForDevice(id.platform_id).map((r) => ({
        requestId: r.request_id,
        days: r.days,
      }));
      res.writeHead(200, { 'Content-Type': 'application/json' }).end(JSON.stringify(rows));
      return;
    }

    if (req.method === 'POST' && url.pathname === '/ios/health/upload') {
      const id = authIdentity(req);
      if (!id) {
        res.writeHead(401, { 'Content-Type': 'application/json' }).end('{"error":"unauthorized"}');
        return;
      }
      readBody(req)
        .then((body) => {
          const parsed = HealthUploadBody.safeParse(JSON.parse(body));
          if (!parsed.success) {
            res
              .writeHead(400, { 'Content-Type': 'application/json' })
              .end(JSON.stringify({ error: 'invalid body', issues: parsed.error.issues }));
            return;
          }
          // Routing is by TOKEN identity, never by body.platformId (which is
          // the client's local id and may not match the server platform_id).
          const requestId = parsed.data.requestId;
          const days = parsed.data.days;
          // The person's HEALTH agent folder under user-memory:
          //   data/user-memory/<person>/<healthAgent>
          const memHealthRoot = userMemoryRoot(id.person_key, healthAgentFolder);
          appendHealthHistory(memHealthRoot, days);
          if (requestId) healthRequestsStore.clear(requestId);
          log('health_history (http)', {
            personKey: id.person_key,
            platformId: id.platform_id,
            count: days.length,
            requestId: requestId ?? null,
          });
          // Fire-and-forget sick-day trigger. Failures here must not block the upload
          // response — we log and move on. The trigger reads the full health.db
          // (cheap, ~14 rows typical) and only does work if the rule fires.
          // Install-specific: SICK_DAY_TARGET_AGENT_GROUP_ID must be set to the
          // agent-group id of the Greg agent (i.e. "greg").
          // Unset = trigger is a no-op, safe default.
          try {
            // Read the SAME per-person rows we just wrote.
            const allRows = loadAllHealthRows(memHealthRoot);
            // Read from .env (process.env fallback for tests / explicit exports).
            // The host doesn't auto-load .env into process.env, so reading the
            // file directly is the canonical pattern (see src/env.ts).
            const targetAgentGroupId =
              process.env.SICK_DAY_TARGET_AGENT_GROUP_ID ||
              readEnvFile(['SICK_DAY_TARGET_AGENT_GROUP_ID']).SICK_DAY_TARGET_AGENT_GROUP_ID;
            void sickDayCheck({
              agentGroupId: targetAgentGroupId,
              ownerKey: id.person_key,
              allRows,
            }).catch((err) => {
              logWarn('sick-day trigger failed', { err: err instanceof Error ? err.message : String(err) });
            });
          } catch (err) {
            logWarn('sick-day trigger setup failed', { err: err instanceof Error ? err.message : String(err) });
          }
          res.writeHead(200, { 'Content-Type': 'application/json' }).end('{"ok":true}');
        })
        .catch((err) => {
          logWarn('health upload failed', { err: err instanceof Error ? err.message : String(err) });
          res
            .writeHead(400, { 'Content-Type': 'application/json' })
            .end(JSON.stringify({ error: String(err instanceof Error ? err.message : err) }));
        });
      return;
    }

    if (req.method === 'POST' && url.pathname === '/ios/proactive') {
      const id = authIdentity(req);
      if (!id) {
        res.writeHead(401, { 'Content-Type': 'application/json' }).end('{"error":"unauthorized"}');
        return;
      }
      readBody(req)
        .then((body) => {
          const obj = JSON.parse(body) as {
            threadId?: string | null;
            text?: string;
            trigger?: string;
            ts?: string;
            tz?: string;
            payload?: Record<string, unknown>;
          };
          // Routing is by TOKEN identity, never by body.platformId. A body
          // platform id is client-supplied and could name a DIFFERENT person's
          // session — accepting it would let an authenticated caller inject a
          // proactive prompt into someone else's agent (confused deputy). We
          // ignore it entirely; only `trigger` must be present in the body.
          const pid = id.platform_id;
          const trigger = obj.trigger ?? null;
          if (!trigger) {
            res.writeHead(400, { 'Content-Type': 'application/json' }).end('{"error":"trigger required"}');
            return;
          }
          const cfg = getChannelSetup();
          if (!cfg) {
            res.writeHead(503, { 'Content-Type': 'application/json' }).end('{"error":"adapter not ready"}');
            return;
          }
          // Build the same multi-line marker the legacy adapter produced
          // so the agent prompt looks identical post-cutover.
          const ts = obj.ts ?? new Date().toISOString();
          const tz = obj.tz ?? '';
          let text = `[proactive trigger=${trigger} ts=${ts}${tz ? ` tz=${tz}` : ''}]`;
          const inlinePayload = obj.payload && typeof obj.payload === 'object' ? obj.payload : {};
          const lines = Object.entries(inlinePayload).map(
            ([k, v]) => `${k}=${typeof v === 'string' ? v : JSON.stringify(v)}`,
          );
          if (lines.length > 0) text += '\n' + lines.join(' ');
          if (obj.text) text += '\n' + obj.text;
          text += '\n---';
          const threadId = obj.threadId ?? null;
          cfg.onInbound(pid, threadId, {
            id: randomUUID(),
            kind: 'chat',
            content: { text, senderId: pid },
            timestamp: new Date().toISOString(),
          });
          res.writeHead(200, { 'Content-Type': 'application/json' }).end('{"ok":true}');
        })
        .catch((err) => {
          logWarn('proactive failed', { err: err instanceof Error ? err.message : String(err) });
          res
            .writeHead(400, { 'Content-Type': 'application/json' })
            .end(JSON.stringify({ error: String(err instanceof Error ? err.message : err) }));
        });
      return;
    }

    if (req.method === 'GET' && url.pathname === '/ios/state') {
      const id = authIdentity(req);
      if (!id) {
        res.writeHead(401, { 'Content-Type': 'application/json' }).end('{"error":"unauthorized"}');
        return;
      }
      // Per-person cross-agent profiles: data/user-memory/<person>/global/profiles
      const profilesDir = join(userGlobalRoot(id.person_key), 'profiles');
      const parsed = new Map<string, ReturnType<typeof parseProfile>>();
      try {
        for (const f of readdirSync(profilesDir)) {
          if (!f.endsWith('.md')) continue;
          const key = f.slice(0, -3);
          if (!AGENT_META[key]) continue;
          try {
            parsed.set(key, parseProfile(key, readFileSync(join(profilesDir, f), 'utf8')));
          } catch {
            /* skip unreadable fragment */
          }
        }
      } catch {
        /* no profiles dir yet */
      }

      const greg = parsed.get('greg');
      const levels = {
        energy: greg?.levels?.energy ?? null,
        stress: greg?.levels?.stress ?? null,
        recovery: greg?.levels?.recovery ?? null,
        readiness: greg?.levels?.readiness ?? null,
        recovery7d: greg?.recovery7d ?? null,
        updated: greg?.updated ?? null,
      };
      const agents = AGENT_ORDER.filter((k) => parsed.has(k)).map((k) => {
        const p = parsed.get(k)!;
        return {
          key: k,
          title: AGENT_META[k].title,
          icon: AGENT_META[k].icon,
          summary: p.summary,
          detail: p.detail,
          updated: p.updated,
        };
      });
      res.writeHead(200, { 'Content-Type': 'application/json' }).end(JSON.stringify({ levels, agents }));
      return;
    }

    res.writeHead(404, { 'Content-Type': 'application/json' }).end('{"error":"not found"}');
  };
}
