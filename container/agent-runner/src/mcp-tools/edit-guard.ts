/**
 * Guard for `edit_message`: an edit may only fix a SLIP — a number, a word, a
 * typo. Anything bigger is a correction the user should see as such, so it goes
 * as a separate message, never as a rewrite of the old bubble. A rewrite erases
 * what the user already read (they can't tell what changed), and delivering new
 * content by editing an old message moves it back to that message's timestamp,
 * reordering the chat (Scrooge edited an old message to deliver a balances list).
 *
 * The owner's rule: at most 10% of the message may change in place. The signal
 * is normalized Levenshtein distance, which a large append inflates too, so one
 * ratio covers rewrites, "stuff a list onto the end" and filling an empty
 * message. It applies at every length: a short message is cheap to resend, and
 * the old under-40-chars exemption let a short "on it" bubble be overwritten
 * wholesale with the answer.
 */
export const MAX_CHANGE_RATIO = 0.1;

/**
 * "Edit my last message" (no explicit id) is a convenience for a FRESH fix. If
 * the latest message is older than this, the convenience no longer applies — the
 * agent almost certainly means to say something new, and silently editing a
 * stale bubble drops the content back to that old timestamp and reorders the
 * chat (Scrooge's 6-day-old target). Past this age, refuse the omit-id edit and
 * make the agent be explicit (pass the #id) or send a new message.
 */
export const EDIT_STALE_LAST_MS = 60 * 60 * 1000; // 60 min

/** Epoch ms of a SQLite `datetime('now')` value ("YYYY-MM-DD HH:MM:SS", UTC). NaN on garbage. */
export function parseSqliteUtcMs(ts: string): number {
  return new Date(ts.replace(' ', 'T') + 'Z').getTime();
}

/** True when the omit-id "edit my last" target is too old to be a fresh fix. */
export function isStaleLastEdit(timestampSqlite: string, nowMs: number): boolean {
  const t = parseSqliteUtcMs(timestampSqlite);
  if (Number.isNaN(t)) return false; // unparseable → don't block
  return nowMs - t > EDIT_STALE_LAST_MS;
}

/** Compact age for an agent-facing message: "12 min", "5h", "6d". */
export function humanizeAge(ms: number): string {
  const min = Math.max(0, Math.round(ms / 60000));
  if (min < 90) return `${min} min`;
  const hr = Math.round(min / 60);
  if (hr < 48) return `${hr}h`;
  return `${Math.round(hr / 24)}d`;
}

/** Normalized Levenshtein distance in [0,1]: 0 = identical, 1 = nothing shared. */
export function changeRatio(a: string, b: string): number {
  if (a === b) return 0;
  const al = a.length;
  const bl = b.length;
  if (al === 0 || bl === 0) return 1;
  return levenshtein(a, b) / Math.max(al, bl);
}

/**
 * Classify an edit: the change ratio and whether it exceeds what may change in
 * place. Single source of truth for the gate decision AND its logged ratio.
 */
export function classifyReplacement(prev: string, next: string): { ratio: number; isReplacement: boolean } {
  const ratio = changeRatio(prev.trim(), next.trim());
  return { ratio, isReplacement: ratio > MAX_CHANGE_RATIO };
}

/**
 * True when `next` changes more of `prev` than a slip fix may — i.e. the
 * correction must be a new message. Delegates to classifyReplacement.
 */
export function isReplacementEdit(prev: string, next: string): boolean {
  return classifyReplacement(prev, next).isReplacement;
}

/** Space-optimized Levenshtein (two rolling rows → O(min(n,m)) memory). */
function levenshtein(a: string, b: string): number {
  if (a.length < b.length) [a, b] = [b, a];
  const m = b.length;
  let prev = new Array<number>(m + 1);
  let curr = new Array<number>(m + 1);
  for (let j = 0; j <= m; j++) prev[j] = j;
  for (let i = 1; i <= a.length; i++) {
    curr[0] = i;
    const ai = a.charCodeAt(i - 1);
    for (let j = 1; j <= m; j++) {
      const cost = ai === b.charCodeAt(j - 1) ? 0 : 1;
      curr[j] = Math.min(prev[j] + 1, curr[j - 1] + 1, prev[j - 1] + cost);
    }
    [prev, curr] = [curr, prev];
  }
  return prev[m];
}
