/**
 * Core MCP tools: send_message, send_file, edit_message, add_reaction.
 *
 * All outbound tools resolve destinations via the local destination map
 * (see destinations.ts). Agents reference destinations by name; the map
 * translates name → routing tuple. Permission enforcement happens on
 * the host side in delivery.ts via the agent_destinations table.
 */
import fs from 'fs';
import path from 'path';

import { getCurrentInReplyTo } from '../current-batch.js';
import { findByName, getAllDestinations } from '../destinations.js';
import {
  getCurrentOutboundTextBySeq,
  getLatestUserFacingOutboundSeq,
  getMessageIdBySeq,
  getOutboundTimestampBySeq,
  getRoutingBySeq,
  isOutboundSeq,
  writeMessageOut,
} from '../db/messages-out.js';
import { getSessionRouting } from '../db/session-routing.js';
import { classifyReplacement, humanizeAge, isStaleLastEdit, parseSqliteUtcMs } from './edit-guard.js';
import { emitGateEvent, type GateEvent } from './gate-events.js';
import { registerTools } from './server.js';
import type { McpToolDefinition } from './types.js';

function log(msg: string): void {
  console.error(`[mcp-tools] ${msg}`);
}

function generateId(): string {
  return `msg-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
}

function ok(text: string) {
  return { content: [{ type: 'text' as const, text }] };
}

function err(text: string) {
  return { content: [{ type: 'text' as const, text: `Error: ${text}` }], isError: true };
}

function destinationList(): string {
  const all = getAllDestinations();
  if (all.length === 0) return '(none)';
  return all.map((d) => d.name).join(', ');
}

// Guard against an agent copying an enormous file into the outbox (OOM / disk).
const MAX_SEND_FILE_BYTES = 100 * 1024 * 1024;

function checkFileSize(resolvedPath: string): string | null {
  const { size } = fs.statSync(resolvedPath);
  if (size > MAX_SEND_FILE_BYTES) {
    return `File too large: ${(size / 1024 / 1024).toFixed(1)}MB (limit ${MAX_SEND_FILE_BYTES / 1024 / 1024}MB)`;
  }
  return null;
}

/**
 * Resolve a destination name to routing fields.
 *
 * If `to` is omitted, use the session's default reply routing (channel +
 * thread the conversation is in) — the agent replies in place.
 *
 * If `to` is specified, look up the named destination. If it resolves to
 * the same channel the session is bound to, the session's thread_id is
 * preserved so replies land in the correct thread. Otherwise thread_id
 * is null (a cross-destination send starts a new conversation).
 */
function resolveRouting(
  to: string | undefined,
): { channel_type: string; platform_id: string; thread_id: string | null; resolvedName: string } | { error: string } {
  if (!to) {
    // Default: reply to whatever thread/channel this session is bound to.
    const session = getSessionRouting();
    if (session.channel_type && session.platform_id) {
      return {
        channel_type: session.channel_type,
        platform_id: session.platform_id,
        thread_id: session.thread_id,
        resolvedName: '(current conversation)',
      };
    }
    // No session routing (e.g., agent-shared or internal-only agent) —
    // fall back to the legacy single-destination shortcut.
    const all = getAllDestinations();
    if (all.length === 0) return { error: 'No destinations configured.' };
    if (all.length > 1) {
      return {
        error: `You have multiple destinations — specify "to". Options: ${all.map((d) => d.name).join(', ')}`,
      };
    }
    to = all[0].name;
  }
  const dest = findByName(to);
  if (!dest) return { error: `Unknown destination "${to}". Known: ${destinationList()}` };
  if (dest.type === 'channel') {
    // If the destination is the same channel the session is bound to,
    // preserve the thread_id so replies land in the correct thread.
    const session = getSessionRouting();
    const threadId =
      session.channel_type === dest.channelType && session.platform_id === dest.platformId ? session.thread_id : null;
    return {
      channel_type: dest.channelType!,
      platform_id: dest.platformId!,
      thread_id: threadId,
      resolvedName: to,
    };
  }
  return { channel_type: 'agent', platform_id: dest.agentGroupId!, thread_id: null, resolvedName: to };
}

export const sendMessage: McpToolDefinition = {
  tool: {
    name: 'send_message',
    description: 'Send a message to a named destination. If you have only one destination, you can omit `to`.',
    inputSchema: {
      type: 'object' as const,
      properties: {
        to: {
          type: 'string',
          description: 'Destination name (e.g., "family", "worker-1"). Optional if you have only one destination.',
        },
        text: { type: 'string', description: 'Message content' },
      },
      required: ['text'],
    },
  },
  async handler(args) {
    const text = args.text as string;
    if (!text) return err('text is required');

    const routing = resolveRouting(args.to as string | undefined);
    if ('error' in routing) return err(routing.error);

    const id = generateId();
    const seq = writeMessageOut({
      id,
      in_reply_to: getCurrentInReplyTo(),
      kind: 'chat',
      platform_id: routing.platform_id,
      channel_type: routing.channel_type,
      thread_id: routing.thread_id,
      content: JSON.stringify({ text }),
    });

    log(`send_message: #${seq} → ${routing.resolvedName}`);
    return ok(`Message sent to ${routing.resolvedName} (id: ${seq})`);
  },
};

export const sendFile: McpToolDefinition = {
  tool: {
    name: 'send_file',
    description: 'Send a file to a named destination. If you have only one destination, you can omit `to`.',
    inputSchema: {
      type: 'object' as const,
      properties: {
        to: { type: 'string', description: 'Destination name. Optional if you have only one destination.' },
        path: { type: 'string', description: 'File path (relative to /workspace/agent/ or absolute)' },
        text: { type: 'string', description: 'Optional accompanying message' },
        filename: { type: 'string', description: 'Display name (default: basename of path)' },
      },
      required: ['path'],
    },
  },
  async handler(args) {
    const filePath = args.path as string;
    if (!filePath) return err('path is required');

    const routing = resolveRouting(args.to as string | undefined);
    if ('error' in routing) return err(routing.error);

    const resolvedPath = path.isAbsolute(filePath) ? filePath : path.resolve('/workspace/agent', filePath);
    if (!fs.existsSync(resolvedPath)) return err(`File not found: ${filePath}`);
    const tooBig = checkFileSize(resolvedPath);
    if (tooBig) return err(tooBig);

    const id = generateId();
    const filename = (args.filename as string) || path.basename(resolvedPath);

    const outboxDir = path.join('/workspace/outbox', id);
    fs.mkdirSync(outboxDir, { recursive: true });
    fs.copyFileSync(resolvedPath, path.join(outboxDir, filename));

    writeMessageOut({
      id,
      in_reply_to: getCurrentInReplyTo(),
      kind: 'chat',
      platform_id: routing.platform_id,
      channel_type: routing.channel_type,
      thread_id: routing.thread_id,
      content: JSON.stringify({ text: (args.text as string) || '', files: [filename] }),
    });

    log(`send_file: ${id} → ${routing.resolvedName} (${filename})`);
    return ok(`File sent to ${routing.resolvedName} (id: ${id}, filename: ${filename})`);
  },
};

export const sendPhoto: McpToolDefinition = {
  tool: {
    name: 'send_photo',
    description:
      'Send an image as an inline Telegram photo (displays in-chat rather than as a download). ' +
      'Only works on Telegram destinations. If you have only one destination, you can omit `to`.',
    inputSchema: {
      type: 'object' as const,
      properties: {
        to: { type: 'string', description: 'Destination name. Optional if you have only one destination.' },
        path: { type: 'string', description: 'Image file path (relative to /workspace/agent/ or absolute)' },
        caption: { type: 'string', description: 'Optional caption text' },
        filename: { type: 'string', description: 'Display filename (default: basename of path)' },
      },
      required: ['path'],
    },
  },
  async handler(args) {
    const filePath = args.path as string;
    if (!filePath) return err('path is required');

    const routing = resolveRouting(args.to as string | undefined);
    if ('error' in routing) return err(routing.error);

    const resolvedPath = path.isAbsolute(filePath) ? filePath : path.resolve('/workspace/agent', filePath);
    if (!fs.existsSync(resolvedPath)) return err(`File not found: ${filePath}`);
    const tooBig = checkFileSize(resolvedPath);
    if (tooBig) return err(tooBig);

    const id = generateId();
    const filename = (args.filename as string) || path.basename(resolvedPath);

    const outboxDir = path.join('/workspace/outbox', id);
    fs.mkdirSync(outboxDir, { recursive: true });
    fs.copyFileSync(resolvedPath, path.join(outboxDir, filename));

    writeMessageOut({
      id,
      in_reply_to: getCurrentInReplyTo(),
      kind: 'chat',
      platform_id: routing.platform_id,
      channel_type: routing.channel_type,
      thread_id: routing.thread_id,
      content: JSON.stringify({
        operation: 'send_photo',
        caption: (args.caption as string) || '',
        files: [filename],
      }),
    });

    log(`send_photo: ${id} → ${routing.resolvedName} (${filename})`);
    return ok(`Photo sent to ${routing.resolvedName} (id: ${id}, filename: ${filename})`);
  },
};

export const editMessage: McpToolDefinition = {
  tool: {
    name: 'edit_message',
    description:
      'Correct an INACCURACY in a message you ALREADY sent — a factual error, a wrong number, a typo. ' +
      'Replaces its full text in place (the user sees the bubble change, marked edited). ' +
      'STRICT — this is ONLY for fixing something wrong in an already-sent message. NEW content ' +
      '(a new answer, a list, an added detail, any reply) must be a NEW message via send_message, ' +
      'NEVER an edit of an old bubble. When in doubt, send a new message. ' +
      'An edit that rewrites most of the message is rejected automatically. ' +
      'Omit `messageId` to edit the LAST message you sent (the common "fix what I just said" case). ' +
      'Pass `messageId` (the numeric id shown in messages) only to target an OLDER message YOU sent — ' +
      'you cannot edit the user\'s messages, only your own. ' +
      'Never invent a messageId — omit it instead.',
    inputSchema: {
      type: 'object' as const,
      properties: {
        messageId: {
          type: 'integer',
          description: 'Numeric id of an older message to edit. Omit to edit your most recent message.',
        },
        text: { type: 'string', description: 'New full message content (replaces the old text)' },
      },
      required: ['text'],
    },
  },
  async handler(args) {
    const text = args.text as string;
    if (!text) return err('text is required');

    // Best-effort telemetry — a logging failure must never break the edit.
    const logGate = (ev: GateEvent): void => {
      try {
        emitGateEvent(ev);
      } catch (e) {
        log(`gate-event emit failed: ${e}`);
      }
    };

    const omitId = args.messageId === undefined || args.messageId === null || args.messageId === '';
    let seq: number;
    if (omitId) {
      const last = getLatestUserFacingOutboundSeq();
      if (last === null) return err('No recent message to edit');
      // "Edit my last message" (no id) is for a FRESH fix. If the latest message
      // is stale, the agent almost certainly means to say something new; editing
      // it silently would drop the content back to that old timestamp and
      // reorder the chat. Refuse and make the target explicit.
      const lastTs = getOutboundTimestampBySeq(last);
      if (lastTs && isStaleLastEdit(lastTs, Date.now())) {
        const ageMs = Date.now() - parseSqliteUtcMs(lastTs);
        logGate({ decision: 'refused_stale', seq: last, omitId: true, ageMs, prev: getCurrentOutboundTextBySeq(last), next: text });
        return err(
          `Your last message is ${humanizeAge(ageMs)} old — "edit my last message" is only for a fresh fix, ` +
            `not for speaking now. To correct that specific old message pass its #id explicitly; to say something ` +
            `new, use send_message.`,
        );
      }
      seq = last;
    } else {
      seq = Number(args.messageId);
      if (!Number.isFinite(seq) || seq <= 0) {
        return err('messageId must be the numeric id shown in messages — or omit it to edit your last message.');
      }
    }

    // Only edit YOUR OWN (outbound) messages. An explicit messageId can resolve
    // to a user/inbound message (getMessageIdBySeq checks inbound too) — editing
    // that would rewrite the user's bubble. Refuse; nudge toward omit-id.
    if (!isOutboundSeq(seq)) {
      logGate({ decision: 'refused_not_own', seq, omitId, next: text });
      return err(`#${seq} isn't a message you sent — you can only edit your own. Omit messageId to edit your last message.`);
    }

    // Corrections only. A near-total rewrite — or stuffing a long list onto an
    // old bubble — is delivering NEW content, which must be a new send_message,
    // not an edit. Editing an old message moves the new text back to that
    // message's timestamp, reordering the chat and hiding the update (the
    // reported Scrooge bug). Compare against the CURRENT text (original + any
    // prior edits) so a run of small corrections doesn't accumulate against a
    // stale anchor and reject a legitimate later fix. Small corrections and
    // short messages pass. See edit-guard.ts.
    const prevText = getCurrentOutboundTextBySeq(seq);
    const cls = classifyReplacement(prevText ?? '', text);
    if (prevText !== null && cls.isReplacement) {
      logGate({ decision: 'refused_replacement', seq, omitId, ratio: cls.ratio, prev: prevText, next: text });
      return err(
        `That edit replaces most of message #${seq} — edit_message is only for correcting an inaccuracy ` +
          `(a wrong number, a typo, a bad clause). New content — a list, a fresh answer, an addition — must be a ` +
          `NEW message: use send_message instead.`,
      );
    }

    const platformId = getMessageIdBySeq(seq);
    if (!platformId) return err(`Message #${seq} not found`);

    const routing = getRoutingBySeq(seq);
    if (!routing || !routing.channel_type || !routing.platform_id) {
      return err(`Cannot determine destination for message #${seq}`);
    }

    const id = generateId();
    writeMessageOut({
      id,
      kind: 'chat',
      platform_id: routing.platform_id,
      channel_type: routing.channel_type,
      thread_id: routing.thread_id,
      content: JSON.stringify({ operation: 'edit', messageId: platformId, text }),
    });

    logGate({ decision: 'allowed', seq, omitId, ratio: cls.ratio, prev: prevText, next: text });
    log(`edit_message: #${seq} → ${platformId}`);
    return ok(`Message edit queued for #${seq}`);
  },
};

export const addReaction: McpToolDefinition = {
  tool: {
    name: 'add_reaction',
    description: 'Add an emoji reaction to a message.',
    inputSchema: {
      type: 'object' as const,
      properties: {
        messageId: { type: 'integer', description: 'Message ID (the numeric id shown in messages)' },
        emoji: { type: 'string', description: 'Emoji name (e.g., thumbs_up, heart, check)' },
      },
      required: ['messageId', 'emoji'],
    },
  },
  async handler(args) {
    const seq = Number(args.messageId);
    const emoji = args.emoji as string;
    if (!seq || !emoji) return err('messageId and emoji are required');

    const platformId = getMessageIdBySeq(seq);
    if (!platformId) return err(`Message #${seq} not found`);

    const routing = getRoutingBySeq(seq);
    if (!routing || !routing.channel_type || !routing.platform_id) {
      return err(`Cannot determine destination for message #${seq}`);
    }

    // Reactions are a platform affordance — the host renders them on Telegram,
    // Slack, etc. Between agents there is nothing to render: the host has no a2a
    // reaction handling at all, so the payload lands as raw JSON noise in the
    // peer's context. Refuse rather than emit garbage.
    if (routing.channel_type === 'agent') {
      return err('Reactions are not supported for agent destinations — send a message instead.');
    }

    const id = generateId();
    writeMessageOut({
      id,
      kind: 'chat',
      platform_id: routing.platform_id,
      channel_type: routing.channel_type,
      thread_id: routing.thread_id,
      content: JSON.stringify({ operation: 'reaction', messageId: platformId, emoji }),
    });

    log(`add_reaction: #${seq} → ${emoji} on ${platformId}`);
    return ok(`Reaction queued for #${seq}`);
  },
};

// `request_context` lives in ./request_context.ts — it is an async deferred
// tool with a different shape (zod input schema, ToolContext-style ctx, a
// Promise that resolves on a matching `context_response`). It is wired into
// the MCP server separately; this file no longer owns it.

registerTools([sendMessage, sendFile, sendPhoto, editMessage, addReaction]);
