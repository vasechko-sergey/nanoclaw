/**
 * Interactive MCP tools: ask_user_question, send_card.
 *
 * ask_user_question is a blocking tool call — it writes a messages_out row
 * with a question card, then polls messages_in for the response.
 */
import { findQuestionResponse, markCompleted } from '../db/messages-in.js';
import { writeMessageOut } from '../db/messages-out.js';
import { findByName, getAllDestinations, resolveDefaultRouting, soleChannelDestination } from '../destinations.js';
import { awaitingQuestionIds } from './awaiting-questions.js';
import { registerTools } from './server.js';
import type { McpToolDefinition } from './types.js';

function log(msg: string): void {
  console.error(`[mcp-tools] ${msg}`);
}

function generateId(): string {
  return `msg-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
}

interface CardRouting {
  channel_type: string;
  platform_id: string;
  thread_id: string | null;
}

/**
 * Where does a card go?
 *
 * Both tools used to read `session_routing` directly, which is empty on every
 * headless/cron session by construction — so a scheduled card was written with
 * NULL routing and the host dropped it at delivery ("Message missing routing
 * fields"). Greg's morning and evening check-ins were written that way for two
 * days and never reached the phone; nothing in the container ever saw an error,
 * because the tool call itself succeeded.
 *
 * Now: the named destination if the caller gave one, else this session's own
 * conversation, else its only human channel. A card is never routed to an
 * agent — buttons need a human to tap them. Failure is returned to the AGENT
 * rather than written to the DB: an unaddressed card is undeliverable, and
 * silently persisting one only moves the failure somewhere nobody reads.
 */
function resolveCardRouting(to: string | undefined): CardRouting | { error: string } {
  if (to) {
    const dest = findByName(to);
    if (!dest) return { error: `unknown destination "${to}"` };
    if (dest.type !== 'channel' || !dest.channelType || !dest.platformId) {
      return { error: `destination "${to}" is an agent — cards can only go to a human channel` };
    }
    return { channel_type: dest.channelType, platform_id: dest.platformId, thread_id: null };
  }

  const session = resolveDefaultRouting();
  if (session.ok && session.via === 'session') {
    return { channel_type: session.channel_type, platform_id: session.platform_id, thread_id: session.thread_id };
  }

  const only = soleChannelDestination();
  if (only) return { channel_type: only.channelType!, platform_id: only.platformId!, thread_id: null };

  const names = getAllDestinations()
    .filter((d) => d.type === 'channel')
    .map((d) => d.name);
  return {
    error:
      names.length === 0
        ? 'no human channel is configured for this session'
        : `several human channels are possible (${names.join(', ')}) — pass "to" to pick one`,
  };
}

function ok(text: string) {
  return { content: [{ type: 'text' as const, text }] };
}

function err(text: string) {
  return { content: [{ type: 'text' as const, text: `Error: ${text}` }], isError: true };
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

export const askUserQuestion: McpToolDefinition = {
  tool: {
    name: 'ask_user_question',
    description:
      'Ask the user a multiple-choice question and wait for their response. This is a blocking call — execution pauses until the user responds or the timeout expires. Provide a short card title (e.g. "Confirm deletion") and an array of options — each option may be a plain string (used as both button label and result value) or an object { label, selectedLabel?, value? } where selectedLabel is the text shown on the card after the user clicks.',
    inputSchema: {
      type: 'object' as const,
      properties: {
        title: { type: 'string', description: 'Short card title shown above the question' },
        question: { type: 'string', description: 'The question to ask' },
        options: {
          type: 'array',
          items: {
            oneOf: [
              { type: 'string' },
              {
                type: 'object',
                properties: {
                  label: { type: 'string' },
                  selectedLabel: { type: 'string' },
                  value: { type: 'string' },
                },
                required: ['label'],
              },
            ],
          },
          description: 'Options for the user to choose from (string or {label, selectedLabel?, value?})',
        },
        timeout: { type: 'number', description: 'Timeout in seconds (default: 300)' },
        to: {
          type: 'string',
          description:
            'Destination name to ask (see your destination list). Optional — defaults to the current conversation, or to your only human channel on a scheduled wake.',
        },
      },
      required: ['title', 'question', 'options'],
    },
  },
  async handler(args) {
    const title = args.title as string;
    const question = args.question as string;
    const rawOptions = args.options as unknown[];
    const timeout = ((args.timeout as number) || 300) * 1000;
    if (!title || !question || !rawOptions?.length) {
      return err('title, question, and options are required');
    }

    const options = rawOptions.map((o) => {
      if (typeof o === 'string') return { label: o, selectedLabel: o, value: o };
      const obj = o as { label: string; selectedLabel?: string; value?: string };
      return {
        label: obj.label,
        selectedLabel: obj.selectedLabel ?? obj.label,
        value: obj.value ?? obj.label,
      };
    });

    const r = resolveCardRouting(args.to as string | undefined);
    if ('error' in r) return err(`cannot ask — ${r.error}`);
    const questionId = generateId();

    // Write question card to outbound.db
    writeMessageOut({
      id: questionId,
      kind: 'chat-sdk',
      platform_id: r.platform_id,
      channel_type: r.channel_type,
      thread_id: r.thread_id,
      content: JSON.stringify({
        type: 'ask_question',
        questionId,
        title,
        question,
        options,
      }),
    });

    log(`ask_user_question: ${questionId} → "${question}" [${options.join(', ')}]`);

    // Claim this questionId for the duration of the poll below. poll-loop.ts's
    // isUnclaimedQuestionResponse() checks this set to decide whether a
    // question_response row belongs to us (skip it, we'll find it via
    // findQuestionResponse ourselves) or is agent-facing (nobody's waiting,
    // e.g. the answer arrived after we already timed out). Without this, the
    // mid-turn drain (poll-loop.ts) could hand our own response row to the
    // agent's turn before we see it — the row gets consumed there, our poll
    // below never finds it, and we hang for the full timeout despite the
    // answer having arrived on time.
    //
    // Added right before the loop and removed in `finally` so every exit path
    // (found, timeout, or a thrown error from findQuestionResponse) releases
    // the claim — a stale entry left behind would silently suppress every
    // future answer to this questionId forever (it can never time out; the
    // set holds it until process exit).
    awaitingQuestionIds.add(questionId);
    try {
      // Poll for response in inbound.db (host writes the response there)
      const deadline = Date.now() + timeout;
      while (Date.now() < deadline) {
        const response = findQuestionResponse(questionId);

        if (response) {
          const parsed = JSON.parse(response.content);
          // Mark the response as completed via processing_ack (outbound.db)
          markCompleted([response.id]);

          log(`ask_user_question response: ${questionId} → ${parsed.selectedOption}`);
          return ok(parsed.selectedOption);
        }

        await sleep(1000);
      }

      log(`ask_user_question timeout: ${questionId}`);
      return err(`Question timed out after ${timeout / 1000}s`);
    } finally {
      awaitingQuestionIds.delete(questionId);
    }
  },
};

export const sendCard: McpToolDefinition = {
  tool: {
    name: 'send_card',
    description: 'Send a structured card (interactive or display-only) to the current conversation.',
    inputSchema: {
      type: 'object' as const,
      properties: {
        card: {
          type: 'object',
          description: 'Card structure with title, description, and optional children/actions',
        },
        fallbackText: { type: 'string', description: 'Text fallback for platforms without card support' },
        to: {
          type: 'string',
          description:
            'Destination name to send to (see your destination list). Optional — defaults to the current conversation, or to your only human channel on a scheduled wake.',
        },
      },
      required: ['card'],
    },
  },
  async handler(args) {
    const card = args.card as Record<string, unknown>;
    if (!card) return err('card is required');

    const r = resolveCardRouting(args.to as string | undefined);
    if ('error' in r) return err(`cannot send card — ${r.error}`);
    const id = generateId();

    writeMessageOut({
      id,
      kind: 'chat-sdk',
      platform_id: r.platform_id,
      channel_type: r.channel_type,
      thread_id: r.thread_id,
      content: JSON.stringify({ type: 'card', card, fallbackText: (args.fallbackText as string) || '' }),
    });

    log(`send_card: ${id}`);
    return ok(`Card sent (id: ${id})`);
  },
};

registerTools([askUserQuestion, sendCard]);
