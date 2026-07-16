import { findByRouting } from './destinations.js';
import type { MessageInRow } from './db/messages-in.js';
import { TIMEZONE, formatLocalTime } from './timezone.js';

/**
 * Command categories for messages starting with '/'.
 * - admin: sender must be in NANOCLAW_ADMIN_USER_IDS
 * - filtered: silently drop (mark completed without processing)
 * - passthrough: pass raw to the agent (no XML wrapping)
 * - none: not a command — format normally
 */
export type CommandCategory = 'admin' | 'filtered' | 'passthrough' | 'none';

const ADMIN_COMMANDS = new Set(['/remote-control', '/clear', '/compact', '/context', '/cost', '/files']);
const FILTERED_COMMANDS = new Set(['/help', '/login', '/logout', '/doctor', '/config', '/start']);

export interface CommandInfo {
  category: CommandCategory;
  command: string; // the command name (e.g., '/clear')
  text: string; // full original text
  senderId: string | null;
}

/**
 * Categorize a message as a command or not.
 * Only applies to chat/chat-sdk messages.
 *
 * The extracted `senderId` is compared against `NANOCLAW_ADMIN_USER_IDS`
 * which stores ids in the namespaced form `<channel_type>:<raw>` (see
 * src/db/users.ts). chat-sdk-bridge serializes `author.userId` as a raw
 * platform id with no prefix, so we prefix it here. If the id already
 * contains a `:` we assume it's pre-namespaced (non-chat-sdk adapters
 * that populate `senderId` directly) and leave it alone.
 */
export function categorizeMessage(msg: MessageInRow): CommandInfo {
  const content = parseContent(msg.content);
  const text = (content.text || '').trim();
  const senderId = extractSenderId(msg, content);

  if (!text.startsWith('/')) {
    return { category: 'none', command: '', text, senderId };
  }

  // Extract the command name (e.g., '/clear' from '/clear some args')
  const command = text.split(/\s/)[0].toLowerCase();

  if (ADMIN_COMMANDS.has(command)) {
    return { category: 'admin', command, text, senderId };
  }

  if (FILTERED_COMMANDS.has(command)) {
    return { category: 'filtered', command, text, senderId };
  }

  return { category: 'passthrough', command, text, senderId };
}

/**
 * Narrow check for /clear — the only command the runner handles directly.
 * All other command gating (filtered, admin) is done by the host router
 * before messages reach the container.
 */
export function isClearCommand(msg: MessageInRow): boolean {
  const content = parseContent(msg.content);
  const text = (content.text || '').trim();
  return text.toLowerCase().startsWith('/clear');
}

/**
 * True for any chat that needs the outer loop's command path: /clear plus
 * admin/passthrough slash commands the SDK can only dispatch when they are
 * a query's first input. Used by the follow-up poller to bail out and let
 * the outer loop reopen the query.
 */
export function isRunnerCommand(msg: MessageInRow): boolean {
  if (msg.kind !== 'chat' && msg.kind !== 'chat-sdk') return false;
  const cat = categorizeMessage(msg).category;
  return cat === 'admin' || cat === 'passthrough';
}

// eslint-disable-next-line @typescript-eslint/no-explicit-any
function extractSenderId(msg: MessageInRow, content: any): string | null {
  const raw: string | null = content?.senderId || content?.author?.userId || null;
  if (!raw) return null;
  // Already namespaced (e.g. "telegram:123") — use as-is.
  if (raw.includes(':')) return raw;
  // Raw platform id from chat-sdk serialization — prefix with channel type.
  if (!msg.channel_type) return raw;
  return `${msg.channel_type}:${raw}`;
}

/**
 * Routing context extracted from messages_in rows.
 * Copied to messages_out by default so responses go back to the sender.
 */
export interface RoutingContext {
  platformId: string | null;
  channelType: string | null;
  threadId: string | null;
  inReplyTo: string | null;
}

/**
 * Extract routing context from a batch of messages.
 * Uses the first message's routing fields.
 */
export function extractRouting(messages: MessageInRow[]): RoutingContext {
  const first = messages[0];
  return {
    platformId: first?.platform_id ?? null,
    channelType: first?.channel_type ?? null,
    threadId: first?.thread_id ?? null,
    inReplyTo: first?.id ?? null,
  };
}

/**
 * Format a batch of messages_in rows into a prompt string.
 *
 * Prepends a `<context ... />` header so the agent always knows what timezone
 * it's in and (for iOS) where/when the user sent the message. Every timestamp
 * the agent sees in message bodies is the user's local time, and every time it
 * produces (schedules, suggests) should be interpreted as local time in that
 * same zone. The header always carries `timezone` (falling back to container
 * `TIMEZONE` env when no message supplies one); iOS-sourced messages also
 * contribute `ts`, `lat`, `lon`, `accuracy`, `locality` when present. Header
 * shape is v1 behavior (src/v1/router.ts:20-22) extended with iOS attrs in v2.
 *
 * Strips routing fields — the agent never sees platform_id, channel_type, thread_id.
 */
export function formatMessages(messages: MessageInRow[]): string {
  const header = buildContextHeader(messages) + '\n';
  if (messages.length === 0) return header;

  // Group by kind
  const chatMessages = messages.filter((m) => m.kind === 'chat' || m.kind === 'chat-sdk');
  const taskMessages = messages.filter((m) => m.kind === 'task');
  const webhookMessages = messages.filter((m) => m.kind === 'webhook');
  const systemMessages = messages.filter((m) => m.kind === 'system');

  const parts: string[] = [];

  if (chatMessages.length > 0) {
    parts.push(formatChatMessages(chatMessages));
  }
  if (taskMessages.length > 0) {
    parts.push(...taskMessages.map(formatTaskMessage));
  }
  if (webhookMessages.length > 0) {
    parts.push(...webhookMessages.map(formatWebhookMessage));
  }
  if (systemMessages.length > 0) {
    parts.push(...systemMessages.map(formatSystemMessage));
  }

  return header + parts.join('\n\n');
}

/**
 * Build the `<context ... />` header for a batch of inbound messages.
 *
 * Always emits the tag. Walks the batch to find the first message with an
 * inline `ios_context` (the typical case is one message per turn) and lifts
 * its attributes — timezone, timestamp→`ts`, lat, lon, accuracy, locality —
 * onto the tag. Falls back to the container `TIMEZONE` env for the timezone
 * attribute when no iOS context is present (preserves non-iOS behavior).
 *
 * All values are XML-escaped.
 */
function buildContextHeader(messages: MessageInRow[]): string {
  const ctx = findFirstIosContext(messages);
  const attrs: string[] = [];

  const tz = (ctx && typeof ctx.timezone === 'string' && ctx.timezone) || TIMEZONE;
  attrs.push(`timezone="${escapeXml(tz)}"`);

  if (ctx) {
    if (typeof ctx.timestamp === 'string' && ctx.timestamp) {
      attrs.push(`ts="${escapeXml(ctx.timestamp)}"`);
    }
    const loc = ctx.location;
    if (loc && typeof loc.lat === 'number' && typeof loc.lon === 'number') {
      attrs.push(`lat="${escapeXml(String(loc.lat))}"`);
      attrs.push(`lon="${escapeXml(String(loc.lon))}"`);
      if (typeof loc.accuracy === 'number') {
        attrs.push(`accuracy="${escapeXml(String(loc.accuracy))}"`);
      }
    }
    if (typeof ctx.locality === 'string' && ctx.locality) {
      attrs.push(`locality="${escapeXml(ctx.locality)}"`);
    }
  }

  return `<context ${attrs.join(' ')} />`;
}

// eslint-disable-next-line @typescript-eslint/no-explicit-any
function findFirstIosContext(messages: MessageInRow[]): any {
  for (const msg of messages) {
    if (msg.kind !== 'chat' && msg.kind !== 'chat-sdk') continue;
    const content = parseContent(msg.content);
    if (content && content.ios_context) return content.ios_context;
  }
  return null;
}

function formatChatMessages(messages: MessageInRow[]): string {
  if (messages.length === 1) {
    return formatSingleChat(messages[0]);
  }

  const lines = ['<messages>'];
  for (const msg of messages) {
    lines.push(formatSingleChat(msg));
  }
  lines.push('</messages>');
  return lines.join('\n');
}

function formatSingleChat(msg: MessageInRow): string {
  const content = parseContent(msg.content);
  const sender = content.sender || content.author?.fullName || content.author?.userName || 'Unknown';
  const time = formatLocalTime(msg.timestamp, TIMEZONE);
  // iOS-app messages carry an inline `ios_context` (location, timezone,
  // locality) that is lifted into the per-turn <context> header by
  // buildContextHeader(). The message body itself is just the raw text.
  const text = content.text || '';
  const idAttr = msg.seq != null ? ` id="${msg.seq}"` : '';
  const replyAttr = content.replyTo?.id ? ` reply_to="${escapeXml(String(content.replyTo.id))}"` : '';
  const replyPrefix = formatReplyContext(content.replyTo);
  const attachmentsSuffix = formatAttachments(content.attachments);

  const fromAttr = originAttr(msg);

  // a2a rows carry the source agent's folder in `content.senderId` (stamped
  // host-side by agent-route.ts). Emit it as a stable id alongside the human
  // name in `sender=`. Gated on channel_type: human messages also populate
  // `senderId` (a platform user id), which is not an agent.
  const agentAttr =
    msg.channel_type === 'agent' && content.senderId ? ` agent="${escapeXml(String(content.senderId))}"` : '';

  return `<message${idAttr}${fromAttr}${agentAttr} sender="${escapeXml(sender)}" time="${escapeXml(time)}"${replyAttr}>${replyPrefix}${escapeXml(text)}${attachmentsSuffix}</message>`;
}

/**
 * Build a ` from="destination_name"` attribute string from a message's routing
 * fields. Shared by all formatters so the agent always knows where a message
 * originated — critical for explicit addressing.
 */
function originAttr(msg: MessageInRow): string {
  const fromDest = findByRouting(msg.channel_type, msg.platform_id);
  if (fromDest) return ` from="${escapeXml(fromDest.name)}"`;
  if (msg.channel_type || msg.platform_id) {
    return ` from="unknown:${escapeXml(msg.channel_type || '')}:${escapeXml(msg.platform_id || '')}"`;
  }
  return '';
}

function formatTaskMessage(msg: MessageInRow): string {
  const content = parseContent(msg.content);
  const from = originAttr(msg);
  const time = formatLocalTime(msg.timestamp, TIMEZONE);
  const parts: string[] = [];
  if (content.scriptOutput) {
    parts.push('Script output:', JSON.stringify(content.scriptOutput, null, 2), '');
  }
  parts.push('Instructions:', content.prompt || '');
  return `<task${from} time="${escapeXml(time)}">${parts.join('\n')}</task>`;
}

function formatWebhookMessage(msg: MessageInRow): string {
  const content = parseContent(msg.content);
  const source = content.source || 'unknown';
  const event = content.event || 'unknown';
  const from = originAttr(msg);
  return `<webhook${from} source="${escapeXml(source)}" event="${escapeXml(event)}">${JSON.stringify(content.payload || content, null, 2)}</webhook>`;
}

function formatSystemMessage(msg: MessageInRow): string {
  const content = parseContent(msg.content);
  const from = originAttr(msg);
  // iOS WorkoutView events (set_log / workout_complete / image_request / swap /
  // …) arrive as `subtype: 'workout_event'` system rows. Render the raw
  // envelope so Payne's workout-mode skill can parse {subtype, event, payload}
  // and branch on `event` — the generic <system_response> shape below drops
  // both the event name and the payload.
  if (content.subtype === 'workout_event') {
    const time = formatLocalTime(msg.timestamp, TIMEZONE);
    const envelope = JSON.stringify({
      subtype: 'workout_event',
      event: content.event,
      payload: content.payload ?? {},
    });
    return `<workout_event${from} event="${escapeXml(String(content.event || 'unknown'))}" time="${escapeXml(time)}">${envelope}</workout_event>`;
  }
  return `<system_response${from} action="${escapeXml(content.action || 'unknown')}" status="${escapeXml(content.status || 'unknown')}">${JSON.stringify(content.result || null)}</system_response>`;
}

/**
 * Render the quoted original inside the <message> body.
 *
 * Matches v1 format (src/v1/router.ts:10-18): `<quoted_message from="X">Y</quoted_message>`.
 * Requires BOTH sender and text — if only id is present the reply_to attribute
 * on the parent <message> carries the link without an inline preview.
 *
 * No truncation here (v1 didn't truncate).
 */
// eslint-disable-next-line @typescript-eslint/no-explicit-any
function formatReplyContext(replyTo: any): string {
  if (!replyTo) return '';
  const sender = replyTo.sender;
  const text = replyTo.text;
  if (!sender || !text) return '';
  return `\n  <quoted_message from="${escapeXml(sender)}">${escapeXml(text)}</quoted_message>\n`;
}

// eslint-disable-next-line @typescript-eslint/no-explicit-any
function formatAttachments(attachments: any[] | undefined): string {
  if (!Array.isArray(attachments) || attachments.length === 0) return '';
  const parts = attachments.map((a) => {
    const name = a.name || a.filename || 'attachment';
    const type = a.type || 'file';
    const localPath = a.localPath ? `/workspace/${a.localPath}` : '';
    const url = a.url || '';
    if (localPath) {
      return `[${type}: ${escapeXml(name)} — saved to ${escapeXml(localPath)}]`;
    }
    return url ? `[${type}: ${escapeXml(name)} (${escapeXml(url)})]` : `[${type}: ${escapeXml(name)}]`;
  });
  return '\n' + parts.join('\n');
}

// eslint-disable-next-line @typescript-eslint/no-explicit-any
function parseContent(json: string): any {
  try {
    return JSON.parse(json);
  } catch {
    return { text: json };
  }
}

function escapeXml(str: string): string {
  return str.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
}

/**
 * Strip `<internal>...</internal>` blocks from agent output, then trim.
 * Ported from v1 (src/v1/router.ts:25-27). Used to remove the agent's
 * own scratchpad/reasoning before a reply goes out over a channel.
 */
export function stripInternalTags(text: string): string {
  return text.replace(/<internal>[\s\S]*?<\/internal>/g, '').trim();
}
