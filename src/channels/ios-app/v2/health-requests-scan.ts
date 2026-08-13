// Drop-directory scanner for agent-written health refetch requests.
//
// The health agent (Greg) writes `health/requests/<id>.json` containing
// `{ "from": "YYYY-MM-DD", "to": "YYYY-MM-DD" }` on every daily run. This turns
// those files into queue rows for GET /ios/health/requests. The file basename
// becomes the request id, so servicing one (POST /ios/health/upload →
// `clear(requestId)`) can delete the file that produced it.
import { existsSync, readFileSync, readdirSync, statSync } from 'node:fs';
import { join } from 'node:path';

export interface ScannedHealthRequest {
  requestId: string;
  from: string;
  to: string;
}

/** Request ids round-trip through the client (POST /ios/health/upload echoes
 *  `requestId`) and are then used to build a filesystem path. Anything outside
 *  this charset — separators, dots, spaces — is rejected rather than escaped. */
export function isSafeRequestId(id: string): boolean {
  return /^[A-Za-z0-9_-]{1,128}$/.test(id);
}

export function healthRequestsDir(agentRoot: string): string {
  return join(agentRoot, 'health', 'requests');
}

const ISO_DAY = /^\d{4}-\d{2}-\d{2}$/;
const MAX_SPAN_DAYS = 400;

/**
 * Files older than `maxAgeMs` are ignored, not deleted. The directory holds
 * every request written since June — before this scanner existed nothing
 * consumed them, so enqueuing the backlog would ask the phone for ~50 windows
 * on the first poll. Only what the agent asked for recently is live.
 */
export function scanHealthRequestFiles(
  dir: string,
  opts: { maxAgeMs?: number; now?: number } = {},
): ScannedHealthRequest[] {
  const maxAgeMs = opts.maxAgeMs ?? 36 * 60 * 60 * 1000;
  const now = opts.now ?? Date.now();
  if (!existsSync(dir)) return [];

  const out: ScannedHealthRequest[] = [];
  for (const name of readdirSync(dir).sort()) {
    if (!name.endsWith('.json')) continue;
    const requestId = name.slice(0, -'.json'.length);
    if (!isSafeRequestId(requestId)) continue;
    const path = join(dir, name);
    try {
      if (now - statSync(path).mtimeMs > maxAgeMs) continue;
      const body = JSON.parse(readFileSync(path, 'utf8')) as { from?: unknown; to?: unknown };
      const from = body.from;
      const to = body.to;
      if (typeof from !== 'string' || typeof to !== 'string') continue;
      if (!ISO_DAY.test(from) || !ISO_DAY.test(to)) continue;
      const span = (Date.parse(`${to}T00:00:00Z`) - Date.parse(`${from}T00:00:00Z`)) / 86_400_000;
      if (!Number.isFinite(span) || span < 0 || span > MAX_SPAN_DAYS) continue;
      out.push({ requestId, from, to });
    } catch {
      // A half-written or malformed file is skipped, not fatal: the agent
      // rewrites one every run.
      continue;
    }
  }
  return out;
}
