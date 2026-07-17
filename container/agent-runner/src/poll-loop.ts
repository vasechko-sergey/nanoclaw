import { validateA2aKind } from '@shared/a2a/kinds.js';

import { findByName, getAllDestinations, resolveDefaultRouting, type DestinationEntry } from './destinations.js';
import { getPendingMessages, markProcessing, markCompleted, type MessageInRow } from './db/messages-in.js';
import { writeMessageOut, resetUserFacingDispatch, getUserFacingDispatchCount } from './db/messages-out.js';
import { getInboundDb, touchHeartbeat, clearStaleProcessingAcks } from './db/connection.js';
import { clearContinuation, migrateLegacyContinuation, setContinuation } from './db/session-state.js';
import { clearCurrentInReplyTo, setCurrentInReplyTo } from './current-batch.js';
import {
  formatMessages,
  extractRouting,
  categorizeMessage,
  isClearCommand,
  isRunnerCommand,
  stripInternalTags,
  type RoutingContext,
} from './formatter.js';
import { onContextResponse } from './mcp-tools/request_context.js';
import type { AgentProvider, AgentQuery, ProviderEvent } from './providers/types.js';
import type { FactualityLevel } from './config.js';
import { extractDataNumbers } from './verification/numbers.js';
import { gateOutboundText } from './verification/poll-gate.js';
import { judgeProse } from './verification/judge.js';
import { hasEnoughProse, shouldJudgeProse } from './verification/prose-trigger.js';
import { runLevel3 } from './verification/level3.js';
import { createHash } from 'node:crypto';
import { existsSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { getSessionRouting } from './db/session-routing.js';

const POLL_INTERVAL_MS = 1000;
const ACTIVE_POLL_INTERVAL_MS = 500;
/**
 * Per-turn SDK idle ceiling. If the underlying provider stream goes this
 * long without yielding ANY event (including the `activity` liveness
 * signal), the poll-loop assumes the stream is wedged, aborts the query,
 * notifies the user, and lets the next message wake a fresh turn.
 *
 * Four minutes is generous for a real tool call (Bash, Edit, MCP) AND for a
 * slow post-tool model response (large tool outputs / web scrapes push the
 * time-to-first-token up), yet still far below the host-side 30-minute
 * container ceiling — fires first, so the user gets a fallback instead of
 * half an hour of silence. Raised from 2m after a real surf-forecast turn
 * stalled on the post-tool summary just past the old ceiling.
 *
 * Symptom this prevents: model emits an assistant text block followed by
 * a tool_use, the tool completes, and the SDK never returns control —
 * the streaming dispatch already sent any complete <message> blocks, but
 * if the model produced text only via the terminal `result` event it
 * was lost. With this watchdog the user at least gets a "[stream stalled]"
 * fallback within 4 minutes — and only if nothing else was delivered this
 * turn (see the suppression in the abort branch below).
 */
const STREAM_IDLE_TIMEOUT_MS = 240_000;

/**
 * Max times the factuality gate may bounce a turn back to the agent to
 * re-ground an ungrounded number before giving up and delivering a hedged
 * version. Keeps a stubborn fabricator from looping forever.
 */
const FACTUALITY_MAX_RETRIES = 2;
// Char budget for the raw tool-output "sources" string handed to the prose judge
// and L3. 8000 was too small for an agent that runs several data scripts a turn
// (bybit-balance + networth + tax-ge + list-tx): the RELAYED script's output got
// truncated out, so its own content read as "unsupported by tool output" and
// bounced. A wider budget keeps every tool's output in view. The number-grounding
// Set is separate and uncapped, so L3's tool-grounded skip is unaffected either way.
const GROUNDING_TEXT_BUDGET = 32000;

function log(msg: string): void {
  console.error(`[poll-loop] ${msg}`);
}

function generateId(): string {
  return `msg-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
}

/**
 * True for the iOS workout-event system rows the host's WorkoutBridge writes
 * (`subtype: 'workout_event'` — set_log / exercise_done / workout_complete /
 * workout_abort / image_request / exercise_swap_request / … ). Unlike MCP-reply
 * system rows (`context_response`), these are AGENT-FACING: Payne's workout-mode
 * skill parses `{subtype, event, payload}` and acts on them. They must therefore
 * survive the `kind !== 'system'` filter and reach the turn. Non-JSON or
 * non-workout content is treated as not-a-workout-event.
 */
export function isWorkoutEventRow(m: MessageInRow): boolean {
  if (m.kind !== 'system') return false;
  try {
    return (JSON.parse(m.content) as { subtype?: string }).subtype === 'workout_event';
  } catch {
    return false;
  }
}

/**
 * Drain `system` rows that carry MCP-tool replies (currently:
 * ios-app `context_response`) into their awaiting Promises, mark them
 * completed, and return the rows that did NOT match — those continue to
 * the agent turn untouched.
 *
 * The host writes `context_response` as a `system` row with content
 * `{ subtype: 'context_response', request_id, data, errors }`. The
 * matching pending promise lives in-memory in
 * `mcp-tools/request_context.ts`; if the request has already timed out
 * the call is a no-op.
 *
 * Important: this consumes the row so the existing
 * `kind !== 'system'` filter downstream still works for any system row we
 * don't recognize (e.g. ask_user_question responses) — those fall
 * through to the original filter unchanged. Non-iOS sessions never see
 * `subtype === 'context_response'` rows, so this is a no-op there.
 */
export function dispatchSystemReplies(rows: MessageInRow[]): MessageInRow[] {
  const consumed: string[] = [];
  const survivors: MessageInRow[] = [];
  for (const row of rows) {
    if (row.kind !== 'system') {
      survivors.push(row);
      continue;
    }
    let parsed: unknown;
    try {
      parsed = JSON.parse(row.content);
    } catch {
      survivors.push(row);
      continue;
    }
    const content = parsed as { subtype?: string; request_id?: string; data?: Record<string, unknown>; errors?: Record<string, string> };
    if (content.subtype === 'context_response' && content.request_id) {
      try {
        onContextResponse({
          request_id: content.request_id,
          data: content.data ?? {},
          errors: content.errors,
        });
      } catch (err) {
        log(`onContextResponse threw: ${err instanceof Error ? err.message : String(err)}`);
      }
      consumed.push(row.id);
      continue;
    }
    survivors.push(row);
  }
  if (consumed.length > 0) {
    markCompleted(consumed);
    log(`Dispatched ${consumed.length} system reply row(s) to in-flight MCP tools`);
  }
  return survivors;
}

const DEFAULT_EXERCISES_DIR = '/workspace/agent/exercises';
const IMAGE_EXTS = ['.gif', '.jpg', '.png'] as const;

/**
 * Auto-serve iOS `image_request` workout events: read the exercise image from
 * the agent's workspace, emit an `image_blob` outbound row (kind 'control', so
 * the host WorkoutBridge forwards it and it never counts as user-facing), and
 * CONSUME the request so it never reaches the LLM — no tokens, no chat-dump.
 *
 * `.gif` is preferred over `.jpg`/`.png` so an animated asset wins automatically.
 * A missing file (or absent slug) is still consumed: iOS keeps its placeholder.
 * Non-image_request rows (chat, set_log, …) pass through untouched.
 *
 * `exercisesDir` is injectable for tests; production is `/workspace/agent/exercises`.
 */
export function serveImageRequests(
  rows: MessageInRow[],
  exercisesDir: string = DEFAULT_EXERCISES_DIR,
): MessageInRow[] {
  const consumed: string[] = [];
  const survivors: MessageInRow[] = [];
  for (const row of rows) {
    if (!isWorkoutEventRow(row)) {
      survivors.push(row);
      continue;
    }
    let ev: { event?: string; payload?: { slug?: string } };
    try {
      ev = JSON.parse(row.content);
    } catch {
      survivors.push(row);
      continue;
    }
    if (ev.event !== 'image_request') {
      survivors.push(row);
      continue;
    }
    const slug = ev.payload?.slug;
    if (slug) {
      const path = IMAGE_EXTS.map((ext) => join(exercisesDir, `${slug}${ext}`)).find((p) => existsSync(p));
      if (path) {
        try {
          const bytes = readFileSync(path);
          const sha256 = createHash('sha256').update(bytes).digest('hex');
          const routing = getSessionRouting();
          writeMessageOut({
            id: generateId(),
            kind: 'control',
            platform_id: routing.platform_id,
            channel_type: routing.channel_type,
            thread_id: routing.thread_id,
            content: JSON.stringify({ type: 'image_blob', payload: { slug, sha256, base64: bytes.toString('base64') } }),
          });
          log(`Served image_blob for ${slug} (${bytes.length}b, sha ${sha256.slice(0, 8)})`);
        } catch (err) {
          log(`serveImageRequests failed for ${slug}: ${err instanceof Error ? err.message : String(err)}`);
        }
      } else {
        log(`No exercise image for ${slug} — iOS keeps placeholder`);
      }
    }
    consumed.push(row.id);
  }
  if (consumed.length > 0) markCompleted(consumed);
  return survivors;
}

export interface PollLoopConfig {
  provider: AgentProvider;
  /**
   * Name of the provider (e.g. "claude", "codex", "opencode"). Used to key
   * the stored continuation per-provider so flipping providers doesn't
   * resurrect a stale id from a different backend.
   */
  providerName: string;
  cwd: string;
  systemContext?: {
    instructions?: string;
  };
  /** Factuality verification level for this agent. Default 0 = no behavior change. */
  factualityLevel?: FactualityLevel;
}

/**
 * Main poll loop. Runs indefinitely until the process is killed.
 *
 * 1. Poll messages_in for pending rows
 * 2. Format into prompt, call provider.query()
 * 3. While query active: continue polling, push new messages via provider.push()
 * 4. On result: write messages_out
 * 5. Mark messages completed
 * 6. Loop
 */
export async function runPollLoop(config: PollLoopConfig): Promise<void> {
  // Resume the agent's prior session from a previous container run if one
  // was persisted. The continuation is opaque to the poll-loop — the
  // provider decides how to use it (Claude resumes a .jsonl transcript,
  // other providers may reload a thread ID, etc.). Keyed per-provider so
  // a Codex thread id never gets handed to Claude or vice versa.
  let continuation: string | undefined = migrateLegacyContinuation(config.providerName);

  if (continuation) {
    log(`Resuming agent session ${continuation}`);
  }

  // Clear leftover 'processing' acks from a previous crashed container.
  // This lets the new container re-process those messages.
  clearStaleProcessingAcks();

  let pollCount = 0;
  let isFirstPoll = true;
  while (true) {
    // Skip system messages — they're responses for MCP tools (e.g., ask_user_question)
    const allPending = getPendingMessages(isFirstPoll);
    // Drain channel-side replies that belong to in-flight MCP tool promises
    // (currently: ios-app context_response). They MUST NOT join the agent's
    // turn — they resolve the pending Promise the tool is awaiting. Mark
    // them completed in the same tick so the host sweep doesn't see stale
    // claims. Returns the rows that survived dispatch. Workout-event system
    // rows are agent-facing (Payne's workout-mode skill consumes them), so
    // they ride through the `kind !== 'system'` filter alongside chat.
    const messages = serveImageRequests(dispatchSystemReplies(allPending)).filter(
      (m) => m.kind !== 'system' || isWorkoutEventRow(m),
    );
    isFirstPoll = false;
    pollCount++;

    // Periodic heartbeat so we know the loop is alive
    if (pollCount % 30 === 0) {
      log(`Poll heartbeat (${pollCount} iterations, ${messages.length} pending)`);
    }

    if (messages.length === 0) {
      await sleep(POLL_INTERVAL_MS);
      continue;
    }

    // Accumulate gate: if the batch contains only trigger=0 rows
    // (context-only, router-stored under ignored_message_policy='accumulate'),
    // don't wake the agent. Leave them `pending` — they'll ride along the
    // next time a real trigger=1 message lands via this same getPendingMessages
    // query. Without this gate, a warm container keeps processing
    // (and potentially responding to) every accumulate-only batch, defeating
    // the "store as context, don't engage" contract. Host-side countDueMessages
    // gates the same way for wake-from-cold (see src/db/session-db.ts).
    if (!messages.some((m) => m.trigger === 1)) {
      await sleep(POLL_INTERVAL_MS);
      continue;
    }

    const ids = messages.map((m) => m.id);

    // Command handling: the host router gates filtered and unauthorized
    // admin commands before they reach the container. The only command
    // the runner handles directly is /clear (session reset). The /clear
    // ack echoes back through the same channel/thread the command came
    // from — never the batch-wide routing, since a mixed-source batch
    // could otherwise misdirect the ack.
    const normalMessages: MessageInRow[] = [];
    const commandIds: string[] = [];

    for (const msg of messages) {
      if ((msg.kind === 'chat' || msg.kind === 'chat-sdk') && isClearCommand(msg)) {
        log('Clearing session (resetting continuation)');
        continuation = undefined;
        clearContinuation(config.providerName);
        writeMessageOut({
          id: generateId(),
          kind: 'chat',
          platform_id: msg.platform_id,
          channel_type: msg.channel_type,
          thread_id: msg.thread_id,
          content: JSON.stringify({ text: 'Session cleared.' }),
        });
        commandIds.push(msg.id);
        continue;
      }
      normalMessages.push(msg);
    }

    if (commandIds.length > 0) {
      markCompleted(commandIds);
    }

    if (normalMessages.length === 0) {
      const remainingIds = ids.filter((id) => !commandIds.includes(id));
      if (remainingIds.length > 0) markCompleted(remainingIds);
      log(`All ${messages.length} message(s) were commands, skipping query`);
      continue;
    }

    // Pre-task scripts: for any task rows with a `script`, run it before the
    // provider call. Scripts returning wakeAgent=false (or erroring) gate
    // their own task row only — surviving messages still go to the agent.
    // Without the scheduling module, the marker block is empty, `keep`
    // falls back to `normalMessages`, and no gating happens.
    let keep: MessageInRow[] = normalMessages;
    let skipped: string[] = [];
    // MODULE-HOOK:scheduling-pre-task:start
    const { applyPreTaskScripts } = await import('./scheduling/task-script.js');
    const preTask = await applyPreTaskScripts(normalMessages);
    keep = preTask.keep;
    skipped = preTask.skipped;
    if (skipped.length > 0) {
      markCompleted(skipped);
      log(`Pre-task script skipped ${skipped.length} task(s): ${skipped.join(', ')}`);
    }
    // MODULE-HOOK:scheduling-pre-task:end

    if (keep.length === 0) {
      log(`All ${normalMessages.length} non-command message(s) gated by script, skipping query`);
      continue;
    }

    // Source partition: when the batch mixes messages from different
    // routing sources (e.g. an a2a from Jarvis-iOS AND an a2a from
    // Jarvis-Tg landed before the agent woke), process only the OLDEST
    // source's group this iteration. The rest stay pending and get
    // picked up on the next poll. Otherwise `extractRouting` would pin
    // all outbound rows to the first message's source, mis-routing
    // replies to the other group(s). See `partitionMessagesBySource`.
    const partitions = partitionMessagesBySource(keep);
    if (partitions.length > 1) {
      log(`Batch spans ${partitions.length} sources — processing oldest, deferring rest`);
    }
    keep = partitions[0];
    const keepIds = new Set(keep.map((m) => m.id));

    // Routing is derived from the partition we actually run, not the full
    // batch — `extractRouting` keys off `messages[0]`, which after a
    // multi-source batch would point at a peer we're not replying to.
    const routing = extractRouting(keep);

    // Format messages: passthrough commands get raw text (only if the
    // provider natively handles slash commands), others get XML.
    const prompt = formatMessagesWithCommands(keep, config.provider.supportsNativeSlashCommands);

    log(`Processing ${keep.length} message(s), kinds: ${[...new Set(keep.map((m) => m.kind))].join(',')}`);

    // Factuality gate: seed the per-turn grounding set with the numbers the
    // user already supplied this turn (the prompt). Tool outputs get folded in
    // as tool_use_end events arrive. When the gate is off this is unused.
    const level = config.factualityLevel ?? 0;
    const gateOn = level >= 1;
    const grounding = new Set<string>();
    const groundingText: string[] = []; // raw tool outputs this turn (Phase 2)
    if (gateOn) {
      for (const n of extractDataNumbers(prompt)) grounding.add(n);
    }

    const query = config.provider.query({
      prompt,
      continuation,
      cwd: config.cwd,
      systemContext: config.systemContext,
    });

    // Process the query while concurrently polling for new messages.
    // Deferred partitions stay `pending` (we never include them here) so
    // the next poll iteration picks them up with their own routing.
    // markProcessing happens here — after partition + script gating — so
    // deferred messages never enter `processing_ack` and remain visible
    // to the next `getPendingMessages` call.
    const skippedSet = new Set(skipped);
    const processingIds = ids.filter(
      (id) => !commandIds.includes(id) && !skippedSet.has(id) && keepIds.has(id),
    );
    markProcessing(processingIds);
    // Publish the batch's in_reply_to so MCP tools (send_message, send_file)
    // can stamp it on outbound rows — needed for a2a return-path routing.
    setCurrentInReplyTo(routing.inReplyTo);
    let leaveForRetry = false;
    try {
      const result = await processQuery(query, routing, processingIds, config.providerName, gateOn, grounding, level, groundingText);
      if (result.continuation && result.continuation !== continuation) {
        continuation = result.continuation;
        setContinuation(config.providerName, continuation);
      }
      leaveForRetry = result.transientError === true;
    } catch (err) {
      const errMsg = err instanceof Error ? err.message : String(err);

      // Stale/corrupt continuation recovery: ask the provider whether
      // this error means the stored continuation is unusable, and clear
      // it so the next attempt starts fresh.
      if (continuation && config.provider.isSessionInvalid(err)) {
        log(`Stale session detected (${continuation}) — clearing for next retry`);
        continuation = undefined;
        clearContinuation(config.providerName);
      }

      // Transient upstream blip thrown out of the stream (overload/5xx/rate
      // limit): leave the batch un-acked for the host to retry with backoff —
      // no error spam to the user, no premature completion. Gated on zero
      // user-facing output this turn, mirroring the result-event path: when the
      // gate is off, <message> blocks stream out during assistant_text events,
      // so a transient thrown AFTER some blocks already shipped must NOT leave
      // the batch for retry — a fresh container would re-run the turn and
      // re-stream the same blocks, double-delivering to the user. With output
      // already delivered, treat the turn as complete (fall through to
      // markCompleted) instead.
      if (isTransientApiError(errMsg)) {
        if (getUserFacingDispatchCount() === 0) {
          log(`Transient API error (thrown) — leaving batch for host retry: ${errMsg}`);
          leaveForRetry = true;
        } else {
          log(
            `Transient API error (thrown) but ${getUserFacingDispatchCount()} message(s) already delivered this turn — completing batch to avoid re-delivery: ${errMsg}`,
          );
        }
      } else if (isAuthError(errMsg)) {
        // Classify credential/auth failures distinctly. Since the host's
        // credential proxy injects an OAuth token that EXPIRES, a 401/403 is
        // an expected, recurring failure mode — surface it legibly:
        //   - operator log marker (CREDENTIAL AUTH FAILURE) so it's greppable
        //   - a plain user message instead of the raw "Error: 401 ... x-api-key"
        //     dump, which leaks internals and tells the user nothing actionable.
        log(`CREDENTIAL AUTH FAILURE — host token likely expired/invalid: ${errMsg}`);
        writeMessageOut({
          id: generateId(),
          kind: 'chat',
          platform_id: routing.platformId,
          channel_type: routing.channelType,
          thread_id: routing.threadId,
          content: JSON.stringify({
            text: 'My credentials were rejected (auth error). The operator needs to refresh the API token — I can’t recover this from here.',
          }),
        });
      } else {
        log(`Query error: ${errMsg}`);
        // Write error response so the user knows something went wrong
        writeMessageOut({
          id: generateId(),
          kind: 'chat',
          platform_id: routing.platformId,
          channel_type: routing.channelType,
          thread_id: routing.threadId,
          content: JSON.stringify({ text: `Error: ${errMsg}` }),
        });
      }
    } finally {
      clearCurrentInReplyTo();
    }

    if (leaveForRetry) {
      // Do NOT markCompleted: the batch stays 'processing'. EXIT the loop
      // (and the container, via index.ts) instead of continuing to poll. The
      // host only resets a stale claim when the container is NOT alive
      // (resetStuckProcessingRows, host-sweep step 4). If we looped back here
      // the container would stay "alive but idle": the host could reclaim the
      // row solely via the 30-minute absolute ceiling — turning a brief
      // upstream blip into 30-min retry cycles. (The idle poll never touches
      // .heartbeat either, so the faster claim-stuck check can't fire.) By
      // returning, the next sweep (≤60s) sees the dead container, resets the
      // row to pending with backoff (+tries), and re-wakes a fresh container
      // promptly. After MAX_TRIES the host force-completes a recurring task so
      // its series still advances (see resetStuckProcessingRows in
      // src/host-sweep.ts).
      log(`Left ${processingIds.length} message(s) un-acked — exiting for prompt host retry (transient API error)`);
      return;
    }

    // Ensure completed even if processQuery ended without a result event
    // (e.g. stream closed unexpectedly).
    markCompleted(processingIds);
    log(`Completed ${ids.length} message(s)`);
  }
}

/**
 * Group messages by routing source so each provider call replies into one
 * consistent destination. Two messages share a partition iff they share
 * `(channel_type, platform_id, thread_id, source_session_id)` — anything
 * else means a reply formed from one would mis-route the other. Partition
 * order follows the first appearance of each key in the input, so the
 * oldest source's group comes first (and that's what poll-loop runs this
 * iteration; later groups stay pending for next iteration).
 *
 * Exported for testing.
 */
export function partitionMessagesBySource(messages: MessageInRow[]): MessageInRow[][] {
  const order: string[] = [];
  const groups = new Map<string, MessageInRow[]>();
  for (const m of messages) {
    const key = JSON.stringify([
      m.channel_type ?? '',
      m.platform_id ?? '',
      m.thread_id ?? '',
      m.source_session_id ?? '',
    ]);
    if (!groups.has(key)) {
      groups.set(key, []);
      order.push(key);
    }
    groups.get(key)!.push(m);
  }
  return order.map((k) => groups.get(k)!);
}

/**
 * Format messages, handling passthrough commands differently.
 * When the provider handles slash commands natively (Claude Code),
 * passthrough commands are sent raw (no XML wrapping) so the SDK can
 * dispatch them. Otherwise they fall through to standard XML formatting.
 */
function formatMessagesWithCommands(messages: MessageInRow[], nativeSlashCommands: boolean): string {
  const parts: string[] = [];
  const normalBatch: MessageInRow[] = [];

  for (const msg of messages) {
    if (nativeSlashCommands && (msg.kind === 'chat' || msg.kind === 'chat-sdk')) {
      const cmdInfo = categorizeMessage(msg);
      if (cmdInfo.category === 'passthrough' || cmdInfo.category === 'admin') {
        // Flush normal batch first
        if (normalBatch.length > 0) {
          parts.push(formatMessages(normalBatch));
          normalBatch.length = 0;
        }
        // Pass raw command text (no XML wrapping) — SDK handles it natively
        parts.push(cmdInfo.text);
        continue;
      }
    }
    normalBatch.push(msg);
  }

  if (normalBatch.length > 0) {
    parts.push(formatMessages(normalBatch));
  }

  return parts.join('\n\n');
}

interface QueryResult {
  continuation?: string;
  /**
   * True when the turn ended in a transient upstream API failure (529/5xx/
   * rate-limit). The caller leaves the batch un-acked so the host's stuck-reset
   * retries it with backoff, instead of completing a task that did no work.
   */
  transientError?: boolean;
}

/**
 * Exported for tests only — `runPollLoop` is the sole production caller. The
 * turn-scoped accumulators below (`dispatchedKeys`, `turnRejects`) live for the
 * length of one query and are only observable from in here, so they cannot be
 * covered through the exported dispatch helpers.
 */
export async function processQuery(
  query: AgentQuery,
  routing: RoutingContext,
  initialBatchIds: string[],
  providerName: string,
  gateOn = false,
  grounding: Set<string> = new Set(),
  level: number = 0,
  groundingText: string[] = [],
): Promise<QueryResult> {
  let queryContinuation: string | undefined;
  let done = false;
  let unwrappedNudged = false;
  // Same lifecycle as `unwrappedNudged`, and deliberately so: at most one
  // reject nudge per user-driven turn, re-armed only when a genuine follow-up
  // arrives. Without that bound, an agent that answers the nudge with a second
  // illegal kind would be nudged again, and again — a self-feeding loop. The
  // second offence is dropped and logged instead; the host bounce (Layer 2) is
  // the backstop for the traffic itself.
  let rejectNudged = false;
  // Set when THIS turn carried a harness_error, and consumed by its `result`.
  // Turn-scoped, unlike the nudge latches above: a limit hit on turn 1 must not
  // disarm the no-wrap guard for the rest of a long-lived query.
  let harnessErrored = false;
  // Set when the turn's `result` is a transient upstream API error (529/5xx/
  // rate-limit) and nothing user-facing was delivered — the batch is left
  // un-acked for the host to retry rather than completed.
  let transientError = false;

  // Concurrent polling: push follow-ups into the active query as they arrive.
  // We do NOT force-end the stream on silence — keeping the query open avoids
  // re-spawning the SDK subprocess (~few seconds) and re-loading the .jsonl
  // transcript on every turn. The Anthropic prompt cache is server-side with
  // a 5-min TTL keyed on prefix hash, so stream lifecycle does NOT affect
  // cache lifetime — close+reopen within 5 min still gets cache hits.
  // Stream liveness is decided host-side via the heartbeat file + processing
  // claim age (see src/host-sweep.ts); if something is truly stuck, the host
  // will kill the container and messages get reset to pending.
  let pollInFlight = false;
  let endedForCommand = false;
  const pollHandle = setInterval(() => {
    if (done || pollInFlight || endedForCommand) return;
    pollInFlight = true;

    void (async () => {
      try {
        const pending = getPendingMessages();

        // Slash commands need a fresh query: /clear resets the SDK's
        // resume id (fixed at sdkQuery() time); admin/passthrough commands
        // (/compact, /cost, …) only dispatch when they're the first input
        // of a query — pushed mid-stream they arrive as plain text and
        // the SDK never runs them. End the stream and leave the rows
        // pending; the outer loop handles them on next iteration via the
        // canonical command path + formatMessagesWithCommands.
        if (pending.some((m) => isRunnerCommand(m))) {
          log('Pending slash command — ending stream so outer loop can process');
          endedForCommand = true;
          query.end();
          return;
        }

        // Skip system messages (MCP tool responses).
        // Thread routing is the router's concern — if a message landed in this
        // session, the agent should see it. Per-thread sessions already isolate
        // threads into separate containers; shared sessions intentionally merge
        // everything. Filtering on thread_id here caused deadlocks when the
        // initial batch and follow-ups had mismatched thread_ids (e.g. a
        // host-generated welcome trigger with null thread vs a Discord DM reply).
        // Same as the outer loop: drain system rows that resolve in-flight
        // MCP tool promises (ios-app context_response) before filtering, so a
        // device reply arriving mid-turn unblocks the awaiting tool.
        // Workout-event system rows are agent-facing — keep them (a set logged
        // or a workout finished mid-turn should reach Payne this turn).
        const newMessages = serveImageRequests(dispatchSystemReplies(pending)).filter(
          (m) => m.kind !== 'system' || isWorkoutEventRow(m),
        );
        if (newMessages.length === 0) return;

        const newIds = newMessages.map((m) => m.id);
        markProcessing(newIds);

        // Run pre-task scripts on follow-ups too — without this, a task that
        // arrives during an active query (e.g. a */10 monitoring cron) bypasses
        // its script gate and always wakes the agent, defeating the gate.
        // Mirrors the initial-batch hook above.
        let keep = newMessages;
        let skipped: string[] = [];
        // MODULE-HOOK:scheduling-pre-task-followup:start
        const { applyPreTaskScripts } = await import('./scheduling/task-script.js');
        const preTask = await applyPreTaskScripts(newMessages);
        keep = preTask.keep;
        skipped = preTask.skipped;
        if (skipped.length > 0) {
          markCompleted(skipped);
          log(`Pre-task script skipped ${skipped.length} follow-up task(s): ${skipped.join(', ')}`);
        }
        // MODULE-HOOK:scheduling-pre-task-followup:end

        if (keep.length === 0) return;
        // Re-check done — the outer query may have finished while the script
        // was awaited. Pushing into a closed stream is wasted work; the
        // claimed messages get released by the host's processing-claim sweep.
        if (done) return;

        const keptIds = keep.map((m) => m.id);
        const prompt = formatMessages(keep);
        log(`Pushing ${keep.length} follow-up message(s) into active query`);
        unwrappedNudged = false;
        rejectNudged = false;
        // Fresh turn — clear the post-result idle bypass so the watchdog
        // can still surface a real stall in this new turn, and zero the
        // user-facing dispatch counter so a stall in this follow-up turn is
        // judged on what THIS turn delivered.
        resultReceived = false;
        resetUserFacingDispatch();
        query.push(prompt);
        // Fold follow-up user numbers into the grounding set too.
        if (gateOn) {
          for (const n of extractDataNumbers(prompt)) grounding.add(n);
        }
        markCompleted(keptIds);
      } catch (err) {
        // Without this catch the rejection escapes the void IIFE and Node
        // terminates the container on unhandled-rejection. The initial-batch
        // path is wrapped by processQuery's outer try/catch; the follow-up
        // path is not, so it needs its own.
        const errMsg = err instanceof Error ? err.message : String(err);
        log(`Follow-up poll error: ${errMsg}`);
      } finally {
        pollInFlight = false;
      }
    })();
  }, ACTIVE_POLL_INTERVAL_MS);

  // Tracks (toName, body) pairs already sent to outbound during the
  // CURRENT TURN — both via the streaming assistant_text path and via the
  // terminal result.text path that closes it. The aggregated result.text
  // contains the same blocks the stream already emitted, so without this
  // set we would deliver each user-facing message twice.
  //
  // Reset on every `result` event: the next turn (push() follow-up inside
  // the same query) is allowed to repeat any block — e.g. consecutive
  // status pings, "done" confirmations, or a follow-up that happens to
  // produce identical text. Cross-turn dedupe would silently drop those.
  let dispatchedKeys = new Set<string>();
  // Blocks the gate refused this turn, from BOTH the streaming path and the
  // result path. Streamed rejects must survive to result time — that is the
  // only point where we can push a nudge back into the query — so they
  // accumulate here and are cleared alongside `dispatchedKeys`.
  let turnRejects: BlockReject[] = [];
  // Buffer for partial <message> blocks that span multiple assistant_text
  // events. Closed blocks are dispatched immediately; the trailing remainder
  // (text after the last </message>, including unclosed <message...) is kept
  // here until more text arrives or the turn ends.
  let streamBuffer = '';

  const iter = query.events[Symbol.asyncIterator]();
  let watchdogFired = false;
  // Tracks whether the SDK has emitted a `result` for the in-flight turn.
  // After `result` the turn is logically done; the iterator stays open only
  // to receive push()-driven follow-ups. If the watchdog fires in that
  // window the right thing is to break out silently — emitting the
  // "[stream stalled]" fallback would clutter the user transcript with
  // a misleading error after a perfectly fine answer. Reset to false on
  // every push() so a genuinely stalled follow-up still gets the fallback.
  let resultReceived = false;
  // Factuality gate: per-turn bounce counters, each capped by
  // FACTUALITY_MAX_RETRIES. Separate budgets so number bounces don't starve the
  // prose judge — a turn may bounce up to N times for numbers AND N for prose.
  let factualityRetries = 0;
  let proseRetries = 0;
  let l3Retries = 0;
  // Tool-use ids that started but haven't reported back. While this set is
  // non-empty, the idle watchdog is in "tool-tolerant" mode: an idle
  // window means a long-running Bash/MCP call, not a wedged stream. The
  // 30-min host absolute-ceiling still backstops a genuinely hung tool.
  const inFlightTools = new Set<string>();
  // The provider's iterator-next() Promise is hoisted out of the loop so
  // a watchdog-driven `continue` (tools in flight) does NOT drop a still-
  // pending event. Without this we would call iter.next() again on the
  // next iteration; many async iterators reject or behave undefined when
  // .next() is called while a prior call is outstanding. Holding the
  // Promise and only clearing it once consumed keeps the read in lock-step
  // with the producer.
  let pendingNext: Promise<IteratorResult<ProviderEvent>> | null = null;

  // Fresh turn: zero the user-facing dispatch counter so the stall-fallback
  // decision below reflects only what THIS turn delivered to the user.
  resetUserFacingDispatch();

  try {
    while (true) {
      if (!pendingNext) pendingNext = iter.next();
      let idleHandle: ReturnType<typeof setTimeout> | undefined;
      const idleP = new Promise<{ idle: true }>((resolve) => {
        idleHandle = setTimeout(() => resolve({ idle: true }), STREAM_IDLE_TIMEOUT_MS);
        // Don't let the watchdog timer hold the event loop alive after the
        // poll-loop is abandoned (e.g. tests aborting via signal, host
        // shutdown). Without this, an orphaned 120s timer per iteration
        // prevents the process from exiting cleanly until it fires.
        (idleHandle as { unref?: () => void }).unref?.();
      });
      const winner = await Promise.race<{ idle: true } | IteratorResult<ProviderEvent>>([pendingNext, idleP]);
      if (idleHandle) clearTimeout(idleHandle);

      if ('idle' in winner) {
        // Tool-tolerant mode: at least one tool_use is still pending its
        // tool_result. Long Bash/MCP calls emit no SDK events between
        // start and end; treating that as a stall would kill perfectly
        // healthy turns. Keep waiting on the same `pendingNext`; the
        // host's 30-minute absolute-ceiling is the real backstop for a
        // hung tool.
        if (inFlightTools.size > 0) {
          log(
            `Stream idle ${STREAM_IDLE_TIMEOUT_MS}ms with ${inFlightTools.size} tool(s) in flight — extending watchdog`,
          );
          continue;
        }

        // SDK stream went silent for STREAM_IDLE_TIMEOUT_MS without yielding
        // even an `activity` tick. Two cases:
        //   - Before `result`: the turn never completed. Tell the user
        //     something stalled, abort, let the next inbound message wake
        //     a fresh turn. Without this, the host's 30-minute ceiling
        //     fires later and the user sees half an hour of silence for
        //     what was actually a dead stream.
        //   - After `result`: the turn finished cleanly; we're only
        //     iterating to catch push() follow-ups. SDK sometimes keeps
        //     the stream open with no further events. Break silently —
        //     the user already has the agent's full answer, the fallback
        //     message would just confuse them.
        if (resultReceived) {
          log(`Stream idle ${STREAM_IDLE_TIMEOUT_MS}ms after result — ending turn cleanly`);
          watchdogFired = true;
          try {
            query.abort();
          } catch (err) {
            log(`query.abort() threw: ${err instanceof Error ? err.message : String(err)}`);
          }
          break;
        }
        log(`Stream idle ${STREAM_IDLE_TIMEOUT_MS}ms — aborting turn`);
        watchdogFired = true;
        if (streamBuffer.length > 0) {
          // Rejects are dropped here on purpose: the turn is being aborted, so
          // there is no query left to push a nudge into. They were logged.
          const { remainder } = dispatchCompleteBlocks(streamBuffer, routing, dispatchedKeys);
          streamBuffer = remainder;
        }
        markCompleted(initialBatchIds);
        // Only surface the "[stream stalled]" error if the user got NOTHING
        // this turn. If real content already went out (streamed <message>
        // blocks, send_message / send_photo) — e.g. a forecast photo
        // followed by a stalled summary — the fallback is a misleading error
        // stapled onto a good answer. Status pings don't count (see
        // isUserFacing in messages-out.ts). The streamBuffer flush above runs
        // first so a just-completed block is reflected in the count.
        const delivered = getUserFacingDispatchCount();
        if (delivered === 0) {
          writeMessageOut({
            id: generateId(),
            kind: 'chat',
            platform_id: routing.platformId,
            channel_type: routing.channelType,
            thread_id: routing.threadId,
            content: JSON.stringify({
              text: '[stream stalled — response cut short. Please retry or rephrase.]',
            }),
          });
        } else {
          log(`Stream stalled but ${delivered} message(s) already delivered this turn — suppressing fallback`);
        }
        try {
          query.abort();
        } catch (err) {
          log(`query.abort() threw: ${err instanceof Error ? err.message : String(err)}`);
        }
        break;
      }

      const next = winner;
      // The pending iter.next() Promise has resolved — clear so the next
      // loop iteration requests the following event.
      pendingNext = null;
      if (next.done) break;
      const event = next.value;

      handleEvent(event, routing);
      touchHeartbeat();

      if (event.type === 'tool_use_start') {
        inFlightTools.add(event.id);
      } else if (event.type === 'tool_use_end') {
        inFlightTools.delete(event.id);
        // Fold this tool's output into the per-turn grounding set so the
        // factuality gate can trace the agent's numbers back to a source.
        if (gateOn && event.output) {
          for (const n of extractDataNumbers(event.output)) grounding.add(n);
          if (level >= 2) {
            const used = groundingText.reduce((a, s) => a + s.length, 0);
            if (used < GROUNDING_TEXT_BUDGET) groundingText.push(event.output.slice(0, GROUNDING_TEXT_BUDGET - used));
          }
        }
      }

      if (event.type === 'init') {
        queryContinuation = event.continuation;
        // Persist immediately so a mid-turn container crash still lets the
        // next wake resume the conversation. Without this, the session id
        // was only written after the full stream completed — if the
        // container died between `init` and `result`, the SDK session was
        // effectively orphaned and the next message started a blank
        // Claude session with no prior context.
        setContinuation(providerName, event.continuation);
      } else if (event.type === 'status_msg') {
        writeMessageOut({
          id: generateId(),
          kind: 'chat',
          platform_id: routing.platformId,
          channel_type: routing.channelType,
          thread_id: routing.threadId,
          content: JSON.stringify({ type: 'status', text: event.text, level: event.level, kind: event.kind }),
        });
      } else if (event.type === 'harness_error') {
        // The harness failed and said so in the agent's voice (usage limit,
        // auth, billing). Deliver it as a system notice and remember it for
        // the turn: the `result` below will echo the same text unwrapped, and
        // the no-wrap nudge must not fire on output the agent never wrote.
        harnessErrored = true;
        deliverHarnessNotice(event.code, event.text);
      } else if (event.type === 'assistant_text') {
        // Stream-side dispatch: peel complete <message> blocks out of the
        // running buffer and send them NOW. Anything past the last
        // </message> (including an unclosed <message ... ) stays in the
        // buffer for the next text event or the final `result` flush.
        // Closed blocks recorded in `dispatchedKeys` so the result-side
        // pass below skips them — no duplicate user-facing messages.
        streamBuffer += event.text;
        // Factuality gate buffers the whole turn: blocks must be gated against
        // the complete grounding set at `result`, so we cannot stream them out
        // early. When the gate is off, dispatch streams as before.
        if (!gateOn) {
          const { remainder, rejects } = dispatchCompleteBlocks(streamBuffer, routing, dispatchedKeys);
          streamBuffer = remainder;
          turnRejects.push(...rejects);
        }
      } else if (event.type === 'result') {
        // Consume the harness-error flag at the turn boundary — read once here,
        // cleared immediately, so every exit from this branch (text, no text,
        // the transient `break` below) re-arms the next turn. The nudge
        // decisions further down use the captured value.
        const harnessErroredThisTurn = harnessErrored;
        harnessErrored = false;
        // Transient upstream failure (529 overloaded / 5xx / rate-limit): the
        // SDK exhausted its own retries and surfaced the error as the turn's
        // result. Do NOT complete the batch — leave it 'processing' so the
        // host's stuck-reset re-runs it with backoff, instead of silently
        // finishing a task that did no work (e.g. a daily publish that never
        // wrote its file). Gated on zero user-facing output this turn so a real
        // answer with an unlucky trailing blip isn't re-run wholesale.
        if (event.text && isTransientApiError(event.text) && getUserFacingDispatchCount() === 0) {
          log(`Transient API error in result — leaving batch for host retry: ${event.text.slice(0, 120)}`);
          transientError = true;
          resultReceived = true;
          inFlightTools.clear();
          try {
            query.abort();
          } catch (err) {
            log(`query.abort() threw: ${err instanceof Error ? err.message : String(err)}`);
          }
          break;
        }
        // A result — with or without text — means the turn is done. Mark
        // the initial batch completed now so the host sweep doesn't see
        // stale 'processing' claims while the query stays open for
        // follow-up pushes. The agent may have responded via MCP
        // (send_message) mid-turn, or the message may not need a response
        // at all — either way the turn is finished.
        markCompleted(initialBatchIds);
        resultReceived = true;
        // Each `result` ends a turn. Clear any orphan tool ids — the SDK
        // should always pair tool_use with tool_result before result, but
        // a misbehaving provider that drops the end event would otherwise
        // leave the watchdog permanently suppressed for this query.
        inFlightTools.clear();
        if (event.text) {
          // Stream buffer may still hold tail scratchpad. Reset it — the
          // result.text below covers the full turn and is the canonical
          // scratchpad source.
          streamBuffer = '';
          if (gateOn) {
            // Factuality gate: every <message> block's numbers must trace to
            // this turn's tool outputs or the user's message. Ungrounded →
            // bounce back to the agent to verify/hedge (capped); on exhaustion
            // deliver a hedged version so the user still gets a reply.
            const verdict = gateOutboundText(event.text, grounding);
            if (!verdict.grounded && factualityRetries < FACTUALITY_MAX_RETRIES) {
              factualityRetries++;
              log(
                `Factuality gate: ungrounded [${verdict.ungrounded.join(', ')}] — bouncing (retry ${factualityRetries}/${FACTUALITY_MAX_RETRIES})`,
              );
              resultReceived = false; // a correction starts a fresh turn
              query.push(
                `<system>Your reply stated these numbers with no source this turn: ${verdict.ungrounded.join(', ')}. ` +
                  `Do not state a number you did not get from a tool/script output or the user this turn. ` +
                  `Call the right tool/script to verify it, or remove/hedge the number, then re-send your full reply.</system>`,
              );
            } else {
              if (!verdict.grounded) {
                log(
                  `Factuality gate: retry budget exhausted — delivering hedged (ungrounded [${verdict.ungrounded.join(', ')}])`,
                );
              }
              // Phase 2: prose judge (full mode) — only when numbers are clean.
              // Mirrors the number-bounce above: on unsupported prose, push a
              // correction + re-arm and SKIP delivery (proseBounced) so the
              // while-loop consumes the regenerated turn. Judge error →
              // fail-closed-soft hedge via finalText. Uses its own proseRetries
              // budget so number bounces don't starve it.
              let proseBounced = false;
              let proseHedge = false;
              const sources = groundingText.join('\n');
              if (
                verdict.grounded &&
                shouldJudgeProse(level, sources, event.text) &&
                proseRetries < FACTUALITY_MAX_RETRIES
              ) {
                try {
                  const prose = await judgeProse(event.text, sources);
                  if (prose.unsupported.length > 0) {
                    proseRetries++;
                    log(
                      `Factuality judge: unsupported prose — bouncing (retry ${proseRetries}/${FACTUALITY_MAX_RETRIES})`,
                    );
                    resultReceived = false; // a correction starts a fresh turn
                    query.push(
                      `<system>A fact-check found these claims in your reply unsupported by this turn's tool output: ` +
                        prose.unsupported.map((u) => `"${u.claim}" (${u.why})`).join('; ') +
                        `. Re-check the tool/script output and correct or remove them, then re-send your full reply.</system>`,
                    );
                    proseBounced = true;
                  }
                } catch (err) {
                  proseHedge = true;
                  log(`Factuality judge error (fail-closed-soft): ${err instanceof Error ? err.message : String(err)}`);
                }
              }
              let l3Bounced = false;
              let l3Hedge: string[] = [];
              if (!proseBounced && level >= 3 && verdict.grounded) {
                // L3 runs up to ~10 sequential verification calls (extract + CoVe
                // per claim + web on the action-relevant slice) inline here. The
                // turn's content is already complete; this deliberately delays
                // DELIVERY (which is gated anyway) to verify it — a conscious
                // latency-for-correctness tradeoff, same posture as the prose judge.
                if (hasEnoughProse(event.text)) {
                  const l3 = await runLevel3(event.text, sources, grounding);
                  log(`Factuality L3: checked=${l3.checked} escalated=${l3.escalated} failed=${l3.failed.length}${l3.error ? ` error=${l3.error}` : ''}`);
                  if (l3.failed.length > 0 && l3Retries < FACTUALITY_MAX_RETRIES) {
                    l3Retries++;
                    resultReceived = false; // a correction starts a fresh turn
                    query.push(
                      `<system>A fact-check could not confirm these claims in your reply: ` +
                        l3.failed.map((f) => `"${f.claim}" (${f.why})`).join('; ') +
                        `. Verify each with a tool/web/source, or remove/clearly hedge it, then re-send your full reply.</system>`,
                    );
                    l3Bounced = true;
                  } else if (l3.failed.length > 0) {
                    l3Hedge = l3.failed.map((f) => f.claim);
                  }
                }
              }
              if (!proseBounced && !l3Bounced) {
                const finalText = !verdict.grounded
                  ? `${event.text}\n\n⚠️ Часть чисел выше я не смог подтвердить по источнику — перепроверь перед использованием.`
                  : proseHedge
                    ? `${event.text}\n\n⚠️ Факты не проверены (проверяльщик недоступен).`
                    : l3Hedge.length > 0
                      ? `${event.text}\n\n⚠️ Эти утверждения я не смог подтвердить — перепроверь: ${l3Hedge.map((c) => `"${c}"`).join(', ')}.`
                      : event.text;
                const { hasUnwrapped, rejects } = dispatchResultText(finalText, routing, dispatchedKeys);
                const rejectsThisTurn = turnRejects.concat(rejects);
                if (hasUnwrapped && !unwrappedNudged && !harnessErroredThisTurn) {
                  unwrappedNudged = true;
                  const destinations = getAllDestinations();
                  const names = destinations.map((d) => d.name).join(', ');
                  resultReceived = false;
                  query.push(
                    `<system>Your response was not delivered — it was not wrapped in <message to="name">...</message> blocks. ` +
                      `All output must be wrapped: use <message to="name"> for content to send, or <internal> for scratchpad. ` +
                      `Your destinations: ${names}. ` +
                      `Please re-send your response with the correct wrapping.</system>`,
                  );
                } else if (hasUnwrapped && harnessErroredThisTurn) {
                  log(`Unwrapped text was the harness notice, not agent output — no-wrap nudge suppressed`);
                }
                if (rejectsThisTurn.length > 0 && !rejectNudged) {
                  rejectNudged = true;
                  resultReceived = false;
                  query.push(buildRejectNudge(rejectsThisTurn));
                }
              }
            }
          } else {
            const { hasUnwrapped, rejects } = dispatchResultText(event.text, routing, dispatchedKeys);
            // Fold in anything the streaming path already refused this turn —
            // one nudge covers the whole turn.
            const rejectsThisTurn = turnRejects.concat(rejects);
            // `harnessErroredThisTurn` suppresses the nudge: the result text is
            // the harness's own notice ("You've hit your limit …"), echoed here
            // unwrapped. Nudging spends another turn against the same limit to
            // re-produce the same text — the agent cannot wrap what it did not
            // write. Already delivered as a system notice above.
            if (hasUnwrapped && !unwrappedNudged && !harnessErroredThisTurn) {
              unwrappedNudged = true;
              const destinations = getAllDestinations();
              const names = destinations.map((d) => d.name).join(', ');
              // Same reset as the channel-push path: the nudge starts a
              // fresh turn, so the post-result fast-exit must re-arm.
              resultReceived = false;
              query.push(
                `<system>Your response was not delivered — it was not wrapped in <message to="name">...</message> blocks. ` +
                  `All output must be wrapped: use <message to="name"> for content to send, or <internal> for scratchpad. ` +
                  `Your destinations: ${names}. ` +
                  `Please re-send your response with the correct wrapping.</system>`,
              );
            } else if (hasUnwrapped && harnessErroredThisTurn) {
              // Corrects the record: dispatchResultText just logged "agent
              // output had no <message…> blocks — nothing was sent", which is
              // wrong twice over here. It was not agent output, and the notice
              // WAS sent — as a system message, above.
              log(`Unwrapped text was the harness notice, not agent output — no-wrap nudge suppressed`);
            }
            if (rejectsThisTurn.length > 0 && !rejectNudged) {
              rejectNudged = true;
              resultReceived = false;
              query.push(buildRejectNudge(rejectsThisTurn));
            }
          }
        } else if (turnRejects.length > 0) {
          // Dropped rather than nudged, deliberately: this turn produced no
          // text, so it either errored out or said nothing. Pushing a nudge
          // would re-arm the watchdog (`resultReceived = false`) against a
          // query that may already be dead, buying a full STREAM_IDLE_TIMEOUT_MS
          // stall and a spurious "[stream stalled]" for a turn that is over —
          // and the provider event carries no success/error discriminator to
          // tell those apart. Same call the watchdog's abort path makes above:
          // no query left to nudge into, and they were logged at reject time.
          // Layer 2 (host) remains the backstop for anything that actually
          // reached messages_out.
          log(`Result with no text — dropping ${turnRejects.length} unreported reject(s) from this turn`);
        }
        // The turn is over — reset both accumulators, on EVERY result. A result
        // with no text is still a turn boundary: providers/claude.ts yields
        // `text: null` for error_max_turns / error_during_execution, and a turn
        // can simply produce no final text.
        //
        // After the dispatch above, never before: the dedupe's only reader is
        // the `dispatchResultText` pass that closes the turn, so clearing early
        // would re-send every block the stream had already delivered. The nudges
        // likewise snapshot `turnRejects` into `rejectsThisTurn` first.
        //
        // Either set surviving a result leaks into the NEXT turn: `turnRejects`
        // nudges the agent to re-send a block it never wrote to a destination it
        // never named, and `dispatchedKeys` silently swallows a byte-identical
        // follow-up — a repeated status ping, a "done" confirmation, a re-sent
        // ack — with no log line to say so.
        dispatchedKeys = new Set<string>();
        turnRejects = [];
      }
    }
  } finally {
    done = true;
    clearInterval(pollHandle);
    if (watchdogFired) {
      // Drain the iterator's return() so the underlying SDK subprocess (if
      // any) gets a chance to clean up. Swallow errors — we're already in
      // the abort path and any further failure is logged for debugging
      // only.
      try {
        await iter.return?.(undefined);
      } catch (err) {
        log(`iterator return after watchdog threw: ${err instanceof Error ? err.message : String(err)}`);
      }
    }
  }

  return { continuation: queryContinuation, transientError };
}

function handleEvent(event: ProviderEvent, _routing: RoutingContext): void {
  switch (event.type) {
    case 'init':
      log(`Session: ${event.continuation}`);
      break;
    case 'assistant_text':
      log(`Assistant text (${event.text.length} chars): ${event.text.slice(0, 200)}`);
      break;
    case 'tool_use_start':
      log(`Tool start: ${event.id}`);
      break;
    case 'tool_use_end':
      log(`Tool end: ${event.id}`);
      break;
    case 'result':
      log(`Result: ${event.text ? event.text.slice(0, 200) : '(empty)'}`);
      break;
    case 'error':
      log(
        `Error: ${event.message} (retryable: ${event.retryable}${event.classification ? `, ${event.classification}` : ''})`,
      );
      break;
    case 'progress':
      log(`Progress: ${event.message}`);
      break;
    case 'status_msg':
      log(`Status [${event.level}/${event.kind ?? 'system'}]: ${event.text}`);
      break;
    case 'harness_error':
      // WARNING-shaped so it survives a log-level filter and greps out of
      // logs/containers.log: this is the harness refusing to run the turn, and
      // for a long time the container log was its only trace anywhere.
      log(`WARNING: harness error [${event.code}] — not agent output: ${event.text || '(no text)'}`);
      break;
  }
}

/**
 * A dispatchable <message> block.
 *
 * The lookahead requires `to="` WITHOUT consuming it, so a <message> lacking
 * `to=` still does not match — exactly as before. That is load-bearing: if
 * such blocks matched they would be consumed, `blockCount` would rise, and
 * `hasUnwrapped` would go false, silently killing the no-wrap nudge in
 * `dispatchResultText`.
 *
 * Group 1 is the attribute blob (`to=` and an optional `kind=`, either order),
 * group 2 the body. `[^>]` confines both the blob and the lookahead to the
 * opening tag, so a body containing `>` can never be read as an attribute.
 */
const MESSAGE_BLOCK_RE = /<message\s+(?=[^>]*\bto=")([^>]*?)\s*>([\s\S]*?)<\/message>/g;

/**
 * Read a double-quoted attribute out of an opening tag's attribute blob.
 * `\b` so `to=` is not matched inside e.g. `auto=`. Returns null when absent.
 */
function attrOf(blob: string, name: string): string | null {
  const m = new RegExp(`\\b${name}="([^"]*)"`).exec(blob);
  return m ? m[1] : null;
}

/**
 * Pull (toName, kind) out of a matched attribute blob. The lookahead in
 * MESSAGE_BLOCK_RE guarantees `to="` is present, but a value containing a raw
 * `>` would truncate the blob mid-attribute, leaving no closing quote to
 * match; that degrades to '' and falls through to the unknown-destination
 * path, which is where the old regex sent such names too.
 */
function parseBlockAttrs(blob: string): { toName: string; kind: string | null } {
  return { toName: attrOf(blob, 'to') ?? '', kind: attrOf(blob, 'kind') };
}

/**
 * Build a dedupe key for a (toName, kind, body) triple. NUL byte separators so
 * one field containing another (or a separator) can't collide. `kind` is part
 * of the key: the same body under a different kind is a different message.
 * Body is trimmed to match the final-result path — the same block sent
 * mid-stream and later returned by the aggregated `result.text` should produce
 * the same key regardless of incidental whitespace differences.
 *
 * The separator is written as the `\0` escape, not a raw 0x00 byte: an earlier
 * revision embedded the literal control character, which made the whole file
 * read as binary to grep/git while rendering as an invisible blank in editors.
 */
function blockKey(toName: string, kind: string | null, body: string): string {
  return `${toName}\0${kind ?? ''}\0${body.trim()}`;
}

/**
 * A block that was NOT delivered, and why. Collected by both dispatch paths
 * and turned into one nudge per turn by `buildRejectNudge`.
 */
export interface BlockReject {
  to: string;
  kind: string | null;
  code: 'unknown_kind' | 'unmarked_json' | 'unknown_destination';
  legal?: string[];
}

/**
 * Layer 1 of the a2a kind gate: is this block allowed out?
 *
 * Runs BEFORE the write to messages_out, so an illegal block is never emitted
 * rather than emitted-and-retracted. Returns the reject, or null when the
 * block is fine.
 *
 * Channels are never gated: `kind` is an a2a concept, and the host writes
 * a2a_kinds NULL for every channel row anyway. The type check is what keeps a
 * future projection change from bouncing human-facing traffic.
 */
function gateBlock(dest: DestinationEntry, toName: string, kind: string | null, body: string): BlockReject | null {
  if (dest.type !== 'agent') return null;
  const verdict = validateA2aKind(kind, body, dest.a2aKinds ?? null);
  if (verdict.ok) return null;
  log(`Rejected <message to="${toName}" kind="${kind ?? ''}">: ${verdict.code}`);
  return { to: toName, kind, code: verdict.code, legal: dest.a2aKinds ?? undefined };
}

/**
 * One nudge per turn describing every rejected block, in the same shape as the
 * established no-wrap nudge. The agent fixes it in the same turn with full
 * context — the strongest correction available, and why Layer 1 exists at all
 * despite the host being authoritative.
 */
export function buildRejectNudge(rejects: BlockReject[]): string {
  const lines = rejects.map((r) => {
    if (r.code === 'unknown_destination') return `• to="${r.to}" — такого адресата нет.`;
    if (r.code === 'unmarked_json') {
      return `• to="${r.to}" — тело похоже на структурное сообщение, но kind= не указан. Поставь kind, либо пришли прозой.`;
    }
    return `• to="${r.to}" kind="${r.kind}" — такой kind не принимается. Легальные: ${(r.legal ?? []).concat('text').join(', ')}.`;
  });
  return (
    `<system>Часть сообщений НЕ доставлена:\n${lines.join('\n')}\n` +
    `Формат: <message to="имя" kind="вид">тело</message>; kind можно опустить для обычного текста. ` +
    `Перешли исправленное.</system>`
  );
}

/**
 * Streaming dispatch: scan the running buffer for COMPLETE <message>
 * blocks (`<message to="…">…</message>`), send each new one to its
 * destination, and return the unconsumed tail. Trailing text (after the
 * last </message>, including a half-open `<message …` with no close yet)
 * stays in the returned remainder for the caller to re-feed on the next
 * assistant_text event.
 *
 * Already-dispatched blocks (by `blockKey`) are skipped — this function
 * shares `dispatched` with `dispatchResultText` so the final-result pass
 * does not re-send anything already streamed out.
 *
 * Scratchpad/unwrapped-text handling is intentionally NOT done here —
 * the buffer may contain a partial block we shouldn't log as scratchpad
 * yet. Scratchpad logging + the no-wrap nudge are decided once at
 * `result` time off the aggregated `result.text`.
 *
 * Rejects are returned rather than nudged here: a turn can stream many text
 * events, and the agent should get ONE nudge covering all of them at result
 * time. The caller accumulates them across the turn.
 */
export function dispatchCompleteBlocks(
  text: string,
  routing: RoutingContext,
  dispatched: Set<string>,
): { remainder: string; rejects: BlockReject[] } {
  MESSAGE_BLOCK_RE.lastIndex = 0;
  let match: RegExpExecArray | null;
  let lastIndex = 0;
  const rejects: BlockReject[] = [];
  while ((match = MESSAGE_BLOCK_RE.exec(text)) !== null) {
    const { toName, kind } = parseBlockAttrs(match[1]);
    const body = match[2].trim();
    lastIndex = MESSAGE_BLOCK_RE.lastIndex;
    const key = blockKey(toName, kind, body);
    if (dispatched.has(key)) continue;
    const dest = findByName(toName);
    if (!dest) {
      log(`Unknown destination in <message to="${toName}">, dropping block`);
      rejects.push({ to: toName, kind, code: 'unknown_destination' });
      dispatched.add(key);
      continue;
    }
    const reject = gateBlock(dest, toName, kind, body);
    if (reject) {
      rejects.push(reject);
      dispatched.add(key);
      continue;
    }
    sendToDestination(dest, body, routing, kind);
    dispatched.add(key);
  }
  return { remainder: text.slice(lastIndex), rejects };
}

/**
 * Parse the agent's final aggregated `result.text` for <message to="…">…
 * </message> blocks and dispatch any not already sent via the streaming
 * path. Text outside of blocks (including <internal>…</internal>) is
 * scratchpad — logged but not sent.
 *
 * `hasUnwrapped` is true only when the WHOLE turn produced no `<message>`
 * blocks at all (block count zero across the aggregated text) AND there
 * is residual scratchpad. The streaming path may have already dispatched
 * every block in `text`; that is NOT "unwrapped" — `blockCount > 0` and
 * the nudge stays silent.
 *
 * The agent must always wrap output in <message to="name">…</message>
 * blocks, even with a single destination. Bare text is scratchpad only.
 */
export function dispatchResultText(
  text: string,
  routing: RoutingContext,
  dispatched: Set<string>,
): { newlySent: number; hasUnwrapped: boolean; rejects: BlockReject[] } {
  MESSAGE_BLOCK_RE.lastIndex = 0;
  let match: RegExpExecArray | null;
  let newlySent = 0;
  let blockCount = 0;
  let lastIndex = 0;
  const scratchpadParts: string[] = [];
  const rejects: BlockReject[] = [];

  while ((match = MESSAGE_BLOCK_RE.exec(text)) !== null) {
    blockCount++;
    if (match.index > lastIndex) {
      scratchpadParts.push(text.slice(lastIndex, match.index));
    }
    const { toName, kind } = parseBlockAttrs(match[1]);
    const body = match[2].trim();
    lastIndex = MESSAGE_BLOCK_RE.lastIndex;

    const key = blockKey(toName, kind, body);
    if (dispatched.has(key)) continue;

    const dest = findByName(toName);
    if (!dest) {
      log(`Unknown destination in <message to="${toName}">, dropping block`);
      scratchpadParts.push(`[dropped: unknown destination "${toName}"] ${body}`);
      rejects.push({ to: toName, kind, code: 'unknown_destination' });
      dispatched.add(key);
      continue;
    }
    const reject = gateBlock(dest, toName, kind, body);
    if (reject) {
      rejects.push(reject);
      dispatched.add(key);
      continue;
    }
    sendToDestination(dest, body, routing, kind);
    dispatched.add(key);
    newlySent++;
  }
  if (lastIndex < text.length) {
    scratchpadParts.push(text.slice(lastIndex));
  }

  const scratchpad = stripInternalTags(scratchpadParts.join(''));

  if (scratchpad) {
    log(`[scratchpad] ${scratchpad.slice(0, 500)}${scratchpad.length > 500 ? '…' : ''}`);
  }

  const hasUnwrapped = blockCount === 0 && !!scratchpad;
  if (hasUnwrapped) {
    log(`WARNING: agent output had no <message to="..."> blocks — nothing was sent`);
  }
  return { newlySent, hasUnwrapped, rejects };
}

/**
 * User-facing wording for a harness failure. The SDK's own text is the payload
 * — it carries the only operational fact that exists nowhere else (a usage
 * limit's reset time), so it goes through verbatim, never parsed or reworded.
 *
 * The prefix is load-bearing, not decoration: the text reads as though the
 * agent wrote it ("You've hit your limit"), and without an explicit disclaimer
 * the owner has no way to tell a harness notice from the agent's own voice.
 * `code` rides along for the operator — it's the greppable discriminator.
 */
export function buildHarnessNoticeText(code: string, text: string): string {
  const detail = text.trim() || `The agent harness reported "${code}" and stopped the turn.`;
  return `⚠️ System notice (not from the agent) — this turn did not complete [${code}]:\n${detail}`;
}

/**
 * Deliver a harness-originated failure notice straight to `messages_out`.
 *
 * Deliberately bypasses the <message to="…"> wrap rule. That rule exists to
 * stop the AGENT leaking its own scratchpad; this text is not the agent's —
 * it's the harness speaking in the agent's voice, and holding it to a rule the
 * agent alone can satisfy is exactly what silenced it in production.
 *
 * No API call is involved: the container writes SQLite and the host polls and
 * delivers. So a rate-limited agent — which by definition cannot get another
 * token out of the model — can still tell its owner what happened.
 *
 * Addressed through the same chain as a bare `send_message` (session routing,
 * then the sole destination). The batch's own routing is NOT used: a cron/
 * headless wake carries none, and that is precisely the case where the agent
 * cannot be asked and the owner is least likely to notice the silence.
 *
 * Never throws. An undeliverable notice is logged and dropped — raising here
 * would strand the batch that is still waiting on this turn's markCompleted.
 */
function deliverHarnessNotice(code: string, text: string): void {
  try {
    const dest = resolveDefaultRouting();
    if (!dest.ok) {
      const detail = dest.options.length > 0 ? `${dest.reason}: ${dest.options.join(', ')}` : dest.reason;
      // WARNING-shaped and greppable: this is the last trace of a notice the
      // owner will never see. The container log is host-captured via
      // src/container-log-sink.ts, so it survives the container's --rm exit.
      log(`WARNING: harness error [${code}] UNDELIVERABLE — no destination (${detail}). Text: ${text || '(none)'}`);
      return;
    }
    writeMessageOut({
      id: generateId(),
      kind: 'chat',
      platform_id: dest.platform_id,
      channel_type: dest.channel_type,
      thread_id: dest.thread_id,
      // `sender: 'system'` is the established marker for host/harness-authored
      // content (container-restart.ts, modules/approvals/primitive.ts). On an
      // agent destination it does double duty: the host's a2a gate passes
      // system notes unconditionally, and stampSenderIdentity leaves a truthy
      // sender alone — so a peer can never mistake this for the agent's own
      // protocol traffic. Channel delivery reads only `text` and ignores it.
      content: JSON.stringify({ text: buildHarnessNoticeText(code, text), sender: 'system' }),
    });
    log(`Harness error [${code}] reported to "${dest.name}" (via ${dest.via}): ${text || '(no text)'}`);
  } catch (err) {
    log(`WARNING: harness error [${code}] delivery threw: ${err instanceof Error ? err.message : String(err)}`);
  }
}

function sendToDestination(
  dest: DestinationEntry,
  body: string,
  routing: RoutingContext,
  kind?: string | null,
): void {
  const platformId = dest.type === 'channel' ? dest.platformId! : dest.agentGroupId!;
  const channelType = dest.type === 'channel' ? dest.channelType! : 'agent';
  // Resolve thread_id per-destination from the most recent inbound message
  // that came from this same channel+platform. In agent-shared sessions,
  // different destinations have different thread contexts — using a single
  // routing.threadId would stamp one channel's thread onto another.
  const destRouting = resolveDestinationThread(channelType, platformId);
  // `kind` is an a2a concept only — channels never carry one, and a stray
  // kind= on a channel block is dropped rather than rendered to a human.
  // Agent messages always carry it explicitly (defaulting to 'text') so the
  // host reads one field rather than inferring intent from its absence.
  //
  // The field is `a2a_kind`, NOT `kind`. DO NOT "simplify" it back — `kind`
  // was already taken, twice over:
  //   - `messages_out.kind` is the ROW kind ('chat' | 'system' | …);
  //   - status rows put a status CATEGORY on content.kind — see the
  //     `status_msg` branch ~line 906 here, which writes
  //     `{type:'status', text, level, kind}` (kind: 'system', from
  //     providers/claude.ts's compact_boundary) stamped with the BATCH's
  //     channel_type. That is 'agent' on every turn woken by an a2a inbound,
  //     so those rows reach the host's a2a gate. The send_status MCP tool
  //     (mcp-tools/status.ts) writes the same shape.
  // A third meaning on `content.kind` made the host gate read a status
  // category as an envelope kind and bounce the agent a compaction notice it
  // never authored. The wire attribute stays `kind="…"` — only this internal
  // field is renamed, and formatter.ts renders it back out as `kind=`.
  const content = dest.type === 'agent' ? { text: body, a2a_kind: kind || 'text' } : { text: body };
  writeMessageOut({
    id: generateId(),
    in_reply_to: destRouting?.inReplyTo ?? routing.inReplyTo,
    kind: 'chat',
    platform_id: platformId,
    channel_type: channelType,
    thread_id: destRouting?.threadId ?? null,
    content: JSON.stringify(content),
  });
}

/**
 * Find the thread_id and message id from the most recent inbound message
 * matching the given channel+platform. Returns null if no match found.
 */
function resolveDestinationThread(
  channelType: string,
  platformId: string,
): { threadId: string | null; inReplyTo: string | null } | null {
  try {
    const db = getInboundDb();
    const row = db
      .prepare(
        `SELECT thread_id, id FROM messages_in
         WHERE channel_type = ? AND platform_id = ?
         ORDER BY seq DESC LIMIT 1`,
      )
      .get(channelType, platformId) as { thread_id: string | null; id: string } | undefined;
    if (row) return { threadId: row.thread_id, inReplyTo: row.id };
  } catch (err) {
    log(`resolveDestinationThread error: ${err instanceof Error ? err.message : String(err)}`);
  }
  return null;
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

/**
 * Heuristic: does an error message look like an authentication/authorization
 * failure from the upstream API (expired/invalid token, rejected key)?
 * Matches the substrings the Anthropic API + Claude Code SDK surface on 401/403.
 */
export function isAuthError(message: string): boolean {
  return /\b401\b|\b403\b|unauthorized|forbidden|authentication|invalid[_\s-]?api[_\s-]?key|x-api-key|oauth.*(expired|invalid)|token.*(expired|invalid|rejected)/i.test(
    message,
  );
}

/**
 * Heuristic: does an error/result string look like a TRANSIENT upstream API
 * failure (overload / rate-limit / 5xx) worth retrying rather than completing
 * the task as if it succeeded? The Claude SDK retries these internally but
 * gives up after its own budget and surfaces the error as the turn's result;
 * leaving the message un-acked lets the host re-run it once the overload clears.
 */
export function isTransientApiError(message: string): boolean {
  return /\b429\b|\b50[0-9]\b|\b529\b|overloaded|rate[_\s-]?limit|too many requests|api error:\s*5/i.test(message);
}
