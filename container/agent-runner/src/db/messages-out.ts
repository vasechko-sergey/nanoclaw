/**
 * Outbound message operations (container side).
 *
 * Writes to outbound.db (container-owned).
 * The host polls this DB (read-only) for undelivered messages.
 */
import { getInboundDb, getOutboundDb } from './connection.js';

function log(msg: string): void {
  console.error(`[messages-out] ${msg}`);
}

export interface MessageOutRow {
  id: string;
  seq: number | null;
  in_reply_to: string | null;
  timestamp: string;
  deliver_after: string | null;
  recurrence: string | null;
  kind: string;
  platform_id: string | null;
  channel_type: string | null;
  thread_id: string | null;
  content: string;
}

export interface WriteMessageOut {
  id: string;
  in_reply_to?: string | null;
  deliver_after?: string | null;
  recurrence?: string | null;
  kind: string;
  platform_id?: string | null;
  channel_type?: string | null;
  thread_id?: string | null;
  content: string;
}

/**
 * Turn-scoped count of user-facing messages written to outbound.
 *
 * Every user-visible send funnels through `writeMessageOut`: streamed
 * <message> blocks (poll-loop `sendToDestination`), the MCP `send_message` /
 * `send_photo` / `edit` / `reaction` tools, etc. The poll-loop resets this at
 * each turn boundary and reads it before writing the "[stream stalled]"
 * fallback: if the turn already delivered real content (e.g. a forecast photo
 * followed by a stalled summary), the fallback is a misleading error stapled
 * onto a good answer and is suppressed.
 *
 * Status pings (`{"type":"status"}`) are progress signals, not answers, so
 * they do not count — a turn that only emitted "working on it…" then stalled
 * should still get the fallback.
 */
let userFacingDispatchCount = 0;

/**
 * Recent-duplicate suppression window for `writeMessageOut`. An identical
 * user-facing message to the same destination written within this many seconds
 * is collapsed to a single delivery (the second write returns the first's seq
 * without inserting a row).
 *
 * Why this exists: two delivery paths converge on `writeMessageOut` and share
 * NO upstream dedup — streamed/result `<message to="…">` blocks (poll-loop
 * `sendToDestination`, deduped only against each other via `dispatchedKeys`)
 * and the `send_message` / `send_photo` / `send_file` MCP tools. An agent that
 * both wraps its answer in a `<message>` block AND calls `send_message` for the
 * same destination delivers the identical message twice — jarvis's "Auth sync"
 * brief went out twice 4s apart on 2026-06-24 for exactly this reason.
 *
 * Why a DB query and not an in-memory set: the nanoclaw MCP server runs as a
 * stdio SUBPROCESS (see container-runner / index.ts mcpServers config), so the
 * `<message>` dispatch (poll-loop process) and the `send_message` write (MCP
 * subprocess) execute in DIFFERENT processes. They share only outbound.db, so
 * the dedup has to be a DB lookup against it — a module-level Set would never
 * span the two writers.
 *
 * Why a time window and not exact per-turn scoping: a turn boundary is
 * process-local state the MCP subprocess can't see, so it can't be the dedup
 * scope across processes. The double-send pattern emits both copies within
 * seconds (the model produces the tool call and the block text together), so a
 * short window catches it with wide margin. The only false positive is an
 * intentional byte-identical re-send to the same destination+thread inside the
 * window — no deployed cron sends identical text that fast, and a duplicate
 * identical line seconds apart is virtually always accidental.
 */
const DEDUP_WINDOW_SECONDS = 90;

export function resetUserFacingDispatch(): void {
  userFacingDispatchCount = 0;
}

export function getUserFacingDispatchCount(): number {
  return userFacingDispatchCount;
}

function isUserFacing(msg: WriteMessageOut): boolean {
  if (msg.kind !== 'chat') return false;
  if (msg.content.includes('"type":"status"')) return false;
  return true;
}

/**
 * Write a new outbound message, auto-assigning an odd seq number.
 * Container uses odd seq (1, 3, 5...), host uses even (2, 4, 6...).
 *
 * The disjoint namespace is load-bearing, not just collision avoidance:
 * seq is the agent-facing message ID returned by send_message and accepted
 * by edit_message / add_reaction, and getMessageIdBySeq() below looks up
 * by seq across BOTH tables. If inbound and outbound could share a seq,
 * the agent's "edit message #5" could resolve to the wrong row.
 *
 * Why the read-max-then-insert below needs no explicit transaction:
 *   - `seq` is UNIQUE in both tables, so a duplicate can never be inserted
 *     silently — a collision throws, it does not corrupt.
 *   - One writer per file: the host owns inbound.db (single Node process),
 *     this container owns outbound.db. Two containers never write the same
 *     outbound.db at once — wakeContainer dedups, and restart is gated on the
 *     old process exiting (killContainer onExit) before the new one spawns.
 *     The only same-file writer is this single-threaded bun process, whose
 *     sync .run() calls can't interleave.
 *   - The cross-DB MAX read can be momentarily stale, but parity (even vs odd)
 *     makes a cross-table collision impossible anyway, so staleness affects
 *     only global ordering, never uniqueness.
 * If that single-writer lifecycle ever changes, wrap the read+insert (here and
 * host-side in session-db.ts) in a BEGIN IMMEDIATE transaction.
 */
export function writeMessageOut(msg: WriteMessageOut): number {
  const userFacing = isUserFacing(msg);
  const outbound = getOutboundDb();

  // Recent-duplicate suppression (see DEDUP_WINDOW_SECONDS). Immediate
  // (non-scheduled) user-facing rows only: scheduled sends (deliver_after) and
  // non-user-facing rows (status pings, system kinds) legitimately recur.
  // Matched against outbound.db so it spans BOTH the poll-loop process (which
  // writes <message> blocks) and the MCP subprocess (which writes send_message)
  // — a module-level set could not. IFNULL() so a NULL channel/platform/thread
  // matches another NULL rather than never matching.
  if (userFacing && !msg.deliver_after) {
    const prior = outbound
      .prepare(
        `SELECT seq FROM messages_out
         WHERE kind = 'chat'
           AND deliver_after IS NULL
           AND content = ?
           AND IFNULL(channel_type, '') = ?
           AND IFNULL(platform_id, '') = ?
           AND IFNULL(thread_id, '') = ?
           AND timestamp >= datetime('now', ?)
         ORDER BY seq DESC
         LIMIT 1`,
      )
      .get(
        msg.content,
        msg.channel_type ?? '',
        msg.platform_id ?? '',
        msg.thread_id ?? '',
        `-${DEDUP_WINDOW_SECONDS} seconds`,
      ) as { seq: number } | undefined;
    if (prior) {
      log(
        `Suppressed duplicate outbound: identical message already sent to ${msg.channel_type}:${msg.platform_id} within ${DEDUP_WINDOW_SECONDS}s (seq ${prior.seq})`,
      );
      return prior.seq;
    }
  }

  const inbound = getInboundDb();

  // Read max seq from both DBs to maintain global ordering.
  // Safe: each side only reads the other DB, never writes to it.
  const maxOut = (outbound.prepare('SELECT COALESCE(MAX(seq), 0) AS m FROM messages_out').get() as { m: number }).m;
  const maxIn = (inbound.prepare('SELECT COALESCE(MAX(seq), 0) AS m FROM messages_in').get() as { m: number }).m;
  const max = Math.max(maxOut, maxIn);
  const nextSeq = max % 2 === 0 ? max + 1 : max + 2; // next odd

  // bun:sqlite requires named parameters to be passed with the prefix character
  // in the JS object keys (better-sqlite3 auto-stripped it, bun:sqlite does not).
  outbound
    .prepare(
      `INSERT INTO messages_out (id, seq, in_reply_to, timestamp, deliver_after, recurrence, kind, platform_id, channel_type, thread_id, content)
     VALUES ($id, $seq, $in_reply_to, datetime('now'), $deliver_after, $recurrence, $kind, $platform_id, $channel_type, $thread_id, $content)`,
    )
    .run({
      $id: msg.id,
      $seq: nextSeq,
      $in_reply_to: msg.in_reply_to ?? null,
      $deliver_after: msg.deliver_after ?? null,
      $recurrence: msg.recurrence ?? null,
      $kind: msg.kind,
      $platform_id: msg.platform_id ?? null,
      $channel_type: msg.channel_type ?? null,
      $thread_id: msg.thread_id ?? null,
      $content: msg.content,
    });

  if (userFacing) userFacingDispatchCount++;

  return nextSeq;
}

/**
 * Look up a message's platform ID by seq number.
 * Searches both inbound and outbound DBs since seq spans both.
 *
 * For inbound messages, the Chat SDK message ID is already the platform message ID
 * (e.g., "6037840640:42" for Telegram).
 *
 * For outbound messages, the internal ID (msg-xxx) won't work for edits/reactions.
 * Instead, look up the platform_message_id from the delivered table (host writes this
 * after successful delivery).
 */
export function getMessageIdBySeq(seq: number): string | null {
  const inbound = getInboundDb();

  // Inbound messages: ID is already the platform message ID
  const inRow = inbound.prepare('SELECT id FROM messages_in WHERE seq = ?').get(seq) as
    | { id: string }
    | undefined;
  if (inRow) return inRow.id;

  // Outbound messages: look up platform message ID from delivered table
  const outRow = getOutboundDb().prepare('SELECT id FROM messages_out WHERE seq = ?').get(seq) as
    | { id: string }
    | undefined;
  if (!outRow) return null;

  // Check if host has stored the platform message ID after delivery
  const deliveredRow = inbound
    .prepare('SELECT platform_message_id FROM delivered WHERE message_out_id = ?')
    .get(outRow.id) as { platform_message_id: string | null } | undefined;
  if (deliveredRow?.platform_message_id) return deliveredRow.platform_message_id;

  // Fallback to internal ID (edits/reactions on undelivered messages won't work)
  return outRow.id;
}

/**
 * Look up the routing fields for a message by seq (for edit/reaction targeting).
 * Returns the channel_type, platform_id, thread_id of the referenced message.
 */
export function getRoutingBySeq(
  seq: number,
): { channel_type: string | null; platform_id: string | null; thread_id: string | null } | null {
  const inbound = getInboundDb();
  const inRow = inbound
    .prepare('SELECT channel_type, platform_id, thread_id FROM messages_in WHERE seq = ?')
    .get(seq) as { channel_type: string | null; platform_id: string | null; thread_id: string | null } | undefined;
  if (inRow) return inRow;

  const outRow = getOutboundDb()
    .prepare('SELECT channel_type, platform_id, thread_id FROM messages_out WHERE seq = ?')
    .get(seq) as { channel_type: string | null; platform_id: string | null; thread_id: string | null } | undefined;
  return outRow ?? null;
}

/**
 * Latest user-facing outbound message's seq (or null). Powers `edit_message`
 * with no explicit id: "fix the message I just said". Like isUserFacing (chat
 * kind, not a status ping), and additionally skips edit/reaction control rows
 * so we target a real message, never a prior correction.
 */
export function getLatestUserFacingOutboundSeq(): number | null {
  const row = getOutboundDb()
    .prepare(
      `SELECT seq FROM messages_out
       WHERE kind = 'chat'
         AND seq IS NOT NULL
         AND content NOT LIKE '%"type":"status"%'
         AND content NOT LIKE '%"operation":"edit"%'
         AND content NOT LIKE '%"operation":"reaction"%'
       ORDER BY seq DESC
       LIMIT 1`,
    )
    .get() as { seq: number } | undefined;
  return row?.seq ?? null;
}

/**
 * Is `seq` one of the agent's OWN outbound messages? `edit_message` uses this to
 * refuse editing a user/inbound message: `getMessageIdBySeq` resolves inbound
 * (user) seqs too, so without this guard an explicit messageId pointing at a
 * user message would rewrite the USER's bubble. Reactions are exempt (reacting
 * to a user message is legitimate).
 */
export function isOutboundSeq(seq: number): boolean {
  return !!getOutboundDb().prepare('SELECT 1 FROM messages_out WHERE seq = ?').get(seq);
}

/**
 * The `text` of an outbound message by seq (or null if the row/text is missing).
 * Used by `edit_message` to compare the current text against the proposed edit
 * so a near-total rewrite (delivering new content) can be refused. Reads the
 * original row's content — good enough as the correction baseline (re-edits of
 * the same bubble target the same chat seq, so this stays the anchor).
 */
export function getOutboundTextBySeq(seq: number): string | null {
  const row = getOutboundDb().prepare('SELECT content FROM messages_out WHERE seq = ?').get(seq) as
    | { content: string }
    | undefined;
  if (!row) return null;
  try {
    const parsed = JSON.parse(row.content) as { text?: unknown };
    return typeof parsed.text === 'string' ? parsed.text : null;
  } catch {
    return null;
  }
}

/** Get undelivered messages (for host polling — reads from outbound.db). */
export function getUndeliveredMessages(): MessageOutRow[] {
  return getOutboundDb()
    .prepare(
      `SELECT * FROM messages_out
       WHERE (deliver_after IS NULL OR deliver_after <= datetime('now'))
       ORDER BY timestamp ASC`,
    )
    .all() as MessageOutRow[];
}
