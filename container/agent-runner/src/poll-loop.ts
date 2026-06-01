import { findByName, getAllDestinations, type DestinationEntry } from './destinations.js';
import { getPendingMessages, markProcessing, markCompleted, type MessageInRow } from './db/messages-in.js';
import { writeMessageOut } from './db/messages-out.js';
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

const POLL_INTERVAL_MS = 1000;
const ACTIVE_POLL_INTERVAL_MS = 500;
/**
 * Per-turn SDK idle ceiling. If the underlying provider stream goes this
 * long without yielding ANY event (including the `activity` liveness
 * signal), the poll-loop assumes the stream is wedged, aborts the query,
 * notifies the user, and lets the next message wake a fresh turn.
 *
 * Two minutes is generous for a real tool call (Bash, Edit, MCP) but
 * far below the host-side 30-minute container ceiling — fires first, so
 * the user gets a fallback message instead of 30 minutes of silence.
 *
 * Symptom this prevents: model emits an assistant text block followed by
 * a tool_use, the tool completes, and the SDK never returns control —
 * the streaming dispatch already sent any complete <message> blocks, but
 * if the model produced text only via the terminal `result` event it
 * was lost. With this watchdog the user at least gets a "[stream stalled]"
 * fallback within 2 minutes.
 */
const STREAM_IDLE_TIMEOUT_MS = 120_000;

function log(msg: string): void {
  console.error(`[poll-loop] ${msg}`);
}

function generateId(): string {
  return `msg-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
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
    // claims. Returns the rows that survived dispatch.
    const messages = dispatchSystemReplies(allPending).filter((m) => m.kind !== 'system');
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
    try {
      const result = await processQuery(query, routing, processingIds, config.providerName);
      if (result.continuation && result.continuation !== continuation) {
        continuation = result.continuation;
        setContinuation(config.providerName, continuation);
      }
    } catch (err) {
      const errMsg = err instanceof Error ? err.message : String(err);
      log(`Query error: ${errMsg}`);

      // Stale/corrupt continuation recovery: ask the provider whether
      // this error means the stored continuation is unusable, and clear
      // it so the next attempt starts fresh.
      if (continuation && config.provider.isSessionInvalid(err)) {
        log(`Stale session detected (${continuation}) — clearing for next retry`);
        continuation = undefined;
        clearContinuation(config.providerName);
      }

      // Write error response so the user knows something went wrong
      writeMessageOut({
        id: generateId(),
        kind: 'chat',
        platform_id: routing.platformId,
        channel_type: routing.channelType,
        thread_id: routing.threadId,
        content: JSON.stringify({ text: `Error: ${errMsg}` }),
      });
    } finally {
      clearCurrentInReplyTo();
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
}

async function processQuery(
  query: AgentQuery,
  routing: RoutingContext,
  initialBatchIds: string[],
  providerName: string,
): Promise<QueryResult> {
  let queryContinuation: string | undefined;
  let done = false;
  let unwrappedNudged = false;

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
        const newMessages = dispatchSystemReplies(pending).filter((m) => m.kind !== 'system');
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
        // Fresh turn — clear the post-result idle bypass so the watchdog
        // can still surface a real stall in this new turn.
        resultReceived = false;
        query.push(prompt);
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

  try {
    while (true) {
      let idleHandle: ReturnType<typeof setTimeout> | undefined;
      const idleP = new Promise<{ idle: true }>((resolve) => {
        idleHandle = setTimeout(() => resolve({ idle: true }), STREAM_IDLE_TIMEOUT_MS);
        // Don't let the watchdog timer hold the event loop alive after the
        // poll-loop is abandoned (e.g. tests aborting via signal, host
        // shutdown). Without this, an orphaned 120s timer per iteration
        // prevents the process from exiting cleanly until it fires.
        (idleHandle as { unref?: () => void }).unref?.();
      });
      const nextP = iter.next();
      const winner = await Promise.race<{ idle: true } | IteratorResult<ProviderEvent>>([nextP, idleP]);
      if (idleHandle) clearTimeout(idleHandle);

      if ('idle' in winner) {
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
          const remainder = dispatchCompleteBlocks(streamBuffer, routing, dispatchedKeys);
          streamBuffer = remainder;
        }
        markCompleted(initialBatchIds);
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
        try {
          query.abort();
        } catch (err) {
          log(`query.abort() threw: ${err instanceof Error ? err.message : String(err)}`);
        }
        break;
      }

      const next = winner;
      if (next.done) break;
      const event = next.value;

      handleEvent(event, routing);
      touchHeartbeat();

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
      } else if (event.type === 'assistant_text') {
        // Stream-side dispatch: peel complete <message> blocks out of the
        // running buffer and send them NOW. Anything past the last
        // </message> (including an unclosed <message ... ) stays in the
        // buffer for the next text event or the final `result` flush.
        // Closed blocks recorded in `dispatchedKeys` so the result-side
        // pass below skips them — no duplicate user-facing messages.
        streamBuffer += event.text;
        const remainder = dispatchCompleteBlocks(streamBuffer, routing, dispatchedKeys);
        streamBuffer = remainder;
      } else if (event.type === 'result') {
        // A result — with or without text — means the turn is done. Mark
        // the initial batch completed now so the host sweep doesn't see
        // stale 'processing' claims while the query stays open for
        // follow-up pushes. The agent may have responded via MCP
        // (send_message) mid-turn, or the message may not need a response
        // at all — either way the turn is finished.
        markCompleted(initialBatchIds);
        resultReceived = true;
        if (event.text) {
          // Stream buffer may still hold tail scratchpad. Reset it — the
          // result.text below covers the full turn and is the canonical
          // scratchpad source.
          streamBuffer = '';
          const { hasUnwrapped } = dispatchResultText(event.text, routing, dispatchedKeys);
          // Per-turn dedupe — drop the set now that the turn is fully
          // closed so any follow-up push() can re-send identical content
          // without being silently suppressed.
          dispatchedKeys = new Set<string>();
          if (hasUnwrapped && !unwrappedNudged) {
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
          }
        }
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

  return { continuation: queryContinuation };
}

function handleEvent(event: ProviderEvent, _routing: RoutingContext): void {
  switch (event.type) {
    case 'init':
      log(`Session: ${event.continuation}`);
      break;
    case 'assistant_text':
      log(`Assistant text (${event.text.length} chars): ${event.text.slice(0, 200)}`);
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
  }
}

const MESSAGE_BLOCK_RE = /<message\s+to="([^"]+)"\s*>([\s\S]*?)<\/message>/g;

/**
 * Build a dedupe key for a (toName, body) pair. NUL byte separator so a
 * name containing the body (or vice versa) can't collide. Body is trimmed
 * to match the final-result path — the same block sent mid-stream and
 * later returned by the aggregated `result.text` should produce the same
 * key regardless of incidental whitespace differences.
 */
function blockKey(toName: string, body: string): string {
  return `${toName} ${body.trim()}`;
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
 */
function dispatchCompleteBlocks(text: string, routing: RoutingContext, dispatched: Set<string>): string {
  MESSAGE_BLOCK_RE.lastIndex = 0;
  let match: RegExpExecArray | null;
  let lastIndex = 0;
  while ((match = MESSAGE_BLOCK_RE.exec(text)) !== null) {
    const toName = match[1];
    const body = match[2].trim();
    lastIndex = MESSAGE_BLOCK_RE.lastIndex;
    const key = blockKey(toName, body);
    if (dispatched.has(key)) continue;
    const dest = findByName(toName);
    if (!dest) {
      log(`Unknown destination in <message to="${toName}">, dropping block`);
      dispatched.add(key);
      continue;
    }
    sendToDestination(dest, body, routing);
    dispatched.add(key);
  }
  return text.slice(lastIndex);
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
function dispatchResultText(
  text: string,
  routing: RoutingContext,
  dispatched: Set<string>,
): { newlySent: number; hasUnwrapped: boolean } {
  MESSAGE_BLOCK_RE.lastIndex = 0;
  let match: RegExpExecArray | null;
  let newlySent = 0;
  let blockCount = 0;
  let lastIndex = 0;
  const scratchpadParts: string[] = [];

  while ((match = MESSAGE_BLOCK_RE.exec(text)) !== null) {
    blockCount++;
    if (match.index > lastIndex) {
      scratchpadParts.push(text.slice(lastIndex, match.index));
    }
    const toName = match[1];
    const body = match[2].trim();
    lastIndex = MESSAGE_BLOCK_RE.lastIndex;

    const key = blockKey(toName, body);
    if (dispatched.has(key)) continue;

    const dest = findByName(toName);
    if (!dest) {
      log(`Unknown destination in <message to="${toName}">, dropping block`);
      scratchpadParts.push(`[dropped: unknown destination "${toName}"] ${body}`);
      dispatched.add(key);
      continue;
    }
    sendToDestination(dest, body, routing);
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
  return { newlySent, hasUnwrapped };
}

function sendToDestination(dest: DestinationEntry, body: string, routing: RoutingContext): void {
  const platformId = dest.type === 'channel' ? dest.platformId! : dest.agentGroupId!;
  const channelType = dest.type === 'channel' ? dest.channelType! : 'agent';
  // Resolve thread_id per-destination from the most recent inbound message
  // that came from this same channel+platform. In agent-shared sessions,
  // different destinations have different thread contexts — using a single
  // routing.threadId would stamp one channel's thread onto another.
  const destRouting = resolveDestinationThread(channelType, platformId);
  writeMessageOut({
    id: generateId(),
    in_reply_to: destRouting?.inReplyTo ?? routing.inReplyTo,
    kind: 'chat',
    platform_id: platformId,
    channel_type: channelType,
    thread_id: destRouting?.threadId ?? null,
    content: JSON.stringify({ text: body }),
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
