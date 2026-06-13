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
//
// Extracted into a standalone factory so tests can mount it on a stub
// `http.Server` without spinning up the full adapter (which requires env
// vars + a live ws server).
import http from 'node:http';
import { randomUUID } from 'node:crypto';
import { existsSync } from 'node:fs';
import { join } from 'node:path';

import type { ChannelSetup } from '../../adapter.js';
import { HealthUploadBody } from '../../../../shared/ios-app-protocol/index.js';
import type { HealthUploadDay } from '../../../../shared/ios-app-protocol/index.js';
import { sickDayCheck } from '../../../modules/health-trigger/sick-day.js';
import { readEnvFile } from '../../../env.js';
import { appendHealthHistory } from './health-ingest.js';
import { openHealthDb, readHealthDays } from './health-db.js';
import type { HealthRequestsStore } from './health-requests-store.js';
import type { PlatformId } from './types.js';

function loadAllHealthRows(groupsDir: string, agentFolder: string): HealthUploadDay[] {
  const path = join(groupsDir, agentFolder, 'health', 'health.db');
  if (!existsSync(path)) return [];
  const db = openHealthDb(path);
  try {
    return readHealthDays(db); // already sorted oldest→newest by date
  } finally {
    db.close();
  }
}

export interface HttpHandlerDeps {
  token: string;
  healthRequestsStore: HealthRequestsStore;
  /** Returns the agent group folder wired to a device, or null. */
  resolveAgentFolderForPlatform: (platformId: PlatformId) => string | null;
  /** Where to write the resolved folder's `health/raw.jsonl`. */
  groupsDir: string;
  /**
   * Optional override directory — if set, ALL devices write to this single
   * health folder (legacy back-compat for installs that pinned
   * IOS_HEALTH_HISTORY_DIR). Absolute path; we split into root + leaf and
   * reuse `appendHealthHistory`.
   */
  healthOverrideDir?: string | null;
  /** Where proactive HTTP fallbacks go — same hook as the WS path. */
  getChannelSetup: () => ChannelSetup | null;
  log: (msg: string, ctx?: Record<string, unknown>) => void;
  logWarn: (msg: string, ctx?: Record<string, unknown>) => void;
}

export function createIosHttpHandler(deps: HttpHandlerDeps) {
  const {
    token,
    healthRequestsStore,
    resolveAgentFolderForPlatform,
    groupsDir,
    healthOverrideDir,
    getChannelSetup,
    log,
    logWarn,
  } = deps;

  const requireToken = (req: http.IncomingMessage, res: http.ServerResponse): boolean => {
    const auth = req.headers.authorization ?? '';
    if (auth !== `Bearer ${token}`) {
      res.writeHead(401, { 'Content-Type': 'application/json' }).end('{"error":"unauthorized"}');
      return false;
    }
    return true;
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
      if (!requireToken(req, res)) return;
      const pid = url.searchParams.get('platformId');
      if (!pid) {
        res.writeHead(400, { 'Content-Type': 'application/json' }).end('{"error":"platformId required"}');
        return;
      }
      const rows = healthRequestsStore.listForDevice(pid).map((r) => ({
        requestId: r.request_id,
        days: r.days,
      }));
      res.writeHead(200, { 'Content-Type': 'application/json' }).end(JSON.stringify(rows));
      return;
    }

    if (req.method === 'POST' && url.pathname === '/ios/health/upload') {
      if (!requireToken(req, res)) return;
      readBody(req)
        .then((body) => {
          const parsed = HealthUploadBody.safeParse(JSON.parse(body));
          if (!parsed.success) {
            res
              .writeHead(400, { 'Content-Type': 'application/json' })
              .end(JSON.stringify({ error: 'invalid body', issues: parsed.error.issues }));
            return;
          }
          const pid = parsed.data.platformId;
          const requestId = parsed.data.requestId;
          const days = parsed.data.days;
          if (!pid && !healthOverrideDir) {
            res.writeHead(400, { 'Content-Type': 'application/json' }).end('{"error":"platformId required"}');
            return;
          }
          let writeRoot: string;
          let writeFolder: string;
          if (healthOverrideDir) {
            // Legacy single-folder override mode.
            const idx = healthOverrideDir.lastIndexOf('/');
            writeRoot = idx > 0 ? healthOverrideDir.slice(0, idx) : '.';
            writeFolder = idx > 0 ? healthOverrideDir.slice(idx + 1) : healthOverrideDir;
            // appendHealthHistory adds a 'health' subdir under the folder,
            // so a path like `.../groups/greg/health` is
            // recreated by passing `groups` + `greg` here. For
            // installs that set IOS_HEALTH_HISTORY_DIR to an exact path
            // ending in `/health`, strip the trailing `/health` segment
            // since appendHealthHistory re-adds it.
            if (writeFolder === 'health') {
              const idx2 = writeRoot.lastIndexOf('/');
              writeFolder = idx2 > 0 ? writeRoot.slice(idx2 + 1) : writeRoot;
              writeRoot = idx2 > 0 ? writeRoot.slice(0, idx2) : '.';
            }
          } else {
            const agentFolder = resolveAgentFolderForPlatform(pid!);
            if (!agentFolder) {
              res.writeHead(404, { 'Content-Type': 'application/json' }).end('{"error":"no agent group"}');
              return;
            }
            writeRoot = groupsDir;
            writeFolder = agentFolder;
          }
          appendHealthHistory(writeRoot, writeFolder, days);
          if (requestId) healthRequestsStore.clear(requestId);
          log('health_history (http)', {
            platformId: pid,
            count: days.length,
            requestId: requestId ?? null,
          });
          // Fire-and-forget sick-day trigger. Failures here must not block the upload
          // response — we log and move on. The trigger reads the full raw.jsonl
          // (cheap, ~14 lines typical) and only does work if the rule fires.
          // Install-specific: SICK_DAY_TARGET_AGENT_GROUP_ID must be set to the
          // agent-group id of the Greg agent (i.e. "greg").
          // Unset = trigger is a no-op, safe default.
          try {
            const allRows = loadAllHealthRows(writeRoot, writeFolder);
            // Read from .env (process.env fallback for tests / explicit exports).
            // The host doesn't auto-load .env into process.env, so reading the
            // file directly is the canonical pattern (see src/env.ts).
            const targetAgentGroupId =
              process.env.SICK_DAY_TARGET_AGENT_GROUP_ID ||
              readEnvFile(['SICK_DAY_TARGET_AGENT_GROUP_ID']).SICK_DAY_TARGET_AGENT_GROUP_ID;
            void sickDayCheck({
              agentGroupId: targetAgentGroupId,
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
      if (!requireToken(req, res)) return;
      readBody(req)
        .then((body) => {
          const obj = JSON.parse(body) as {
            platformId?: string;
            threadId?: string | null;
            text?: string;
            trigger?: string;
            ts?: string;
            tz?: string;
            payload?: Record<string, unknown>;
          };
          const pid = obj.platformId;
          const trigger = obj.trigger ?? null;
          if (!pid || !trigger) {
            res
              .writeHead(400, { 'Content-Type': 'application/json' })
              .end('{"error":"platformId and trigger required"}');
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

    res.writeHead(404, { 'Content-Type': 'application/json' }).end('{"error":"not found"}');
  };
}
