/**
 * Greg's readiness signal, kept as a structured file in the person's shared
 * wiki: data/user-memory/<person>/shared/health/signal.json
 * (/workspace/shared/health/signal.json inside every agent container).
 *
 * Greg sends `health_signal` to Payne as an a2a message. That message lived
 * only in Payne's conversation context — a context reset wiped it, and the
 * free-form memories/health_signal_today.md Payne was meant to keep had gone
 * stale for weeks. The plan builder needs the day's level deterministically
 * (container/agent-runner/src/workout-plan.ts readinessFor), so the host —
 * which routes every signal anyway — persists the latest one here, validated,
 * on each route. Greg skips green days, so a reader treats a file dated
 * another day as "no signal today".
 *
 * Best effort: a malformed signal is skipped (the last good file stays), and
 * no failure here may break routing.
 */
import fs from 'fs';
import path from 'path';

import { log } from '../../log.js';

const LEVELS = new Set(['green', 'yellow', 'red']);

/**
 * If `content` (an a2a message body) is a `health_signal`, write its payload to
 * `<sharedRoot>/health/signal.json`. Returns whether the file was written.
 */
export function persistHealthSignal(content: string, sharedRoot: string, now: Date = new Date()): boolean {
  try {
    let msg: { text?: unknown; a2a_kind?: unknown; senderId?: unknown };
    try {
      msg = JSON.parse(content);
    } catch {
      return false;
    }
    if (!msg || msg.a2a_kind !== 'health_signal' || typeof msg.text !== 'string') return false;

    let signal: Record<string, unknown>;
    try {
      signal = JSON.parse(msg.text);
    } catch {
      log.warn('health_signal is not JSON — signal file left as is', { text: msg.text.slice(0, 120) });
      return false;
    }
    if (
      !signal ||
      typeof signal !== 'object' ||
      typeof signal.date !== 'string' ||
      !/^\d{4}-\d{2}-\d{2}$/.test(signal.date) ||
      !LEVELS.has(signal.level as string)
    ) {
      log.warn('health_signal without a valid date/level — signal file left as is', {
        date: signal?.date,
        level: signal?.level,
      });
      return false;
    }

    const record = {
      ...signal,
      received_at: now.toISOString(),
      ...(typeof msg.senderId === 'string' ? { from: msg.senderId } : {}),
    };
    const dir = path.join(sharedRoot, 'health');
    fs.mkdirSync(dir, { recursive: true });
    const target = path.join(dir, 'signal.json');
    fs.writeFileSync(`${target}.tmp`, JSON.stringify(record, null, 2) + '\n');
    fs.renameSync(`${target}.tmp`, target);
    log.info('Health signal kept', { date: signal.date, level: signal.level, file: target });
    return true;
  } catch (err) {
    log.warn('health_signal file write failed', { err });
    return false;
  }
}
