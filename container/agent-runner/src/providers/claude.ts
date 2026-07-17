import fs from 'fs';
import path from 'path';

import { query as sdkQuery, type HookCallback, type PreCompactHookInput } from '@anthropic-ai/claude-agent-sdk';

import { clearContainerToolInFlight, setContainerToolInFlight } from '../db/connection.js';
import { lockForToolCall, unlockAfterToolCall } from '../shared-code-lock.js';
import { registerProvider } from './provider-registry.js';
import type { AgentProvider, AgentQuery, McpServerConfig, ProviderEvent, ProviderOptions, QueryInput } from './types.js';

function log(msg: string): void {
  console.error(`[claude-provider] ${msg}`);
}

/**
 * Pull plain text out of an SDK tool_result `content` field, which may be a
 * string or an array of `{ type: 'text', text }` blocks. Feeds the factuality
 * gate's per-turn grounding set (see verification/). Returns '' for shapes we
 * can't read (images, structured blocks without text).
 */
export function extractToolResultText(content: unknown): string {
  if (typeof content === 'string') return content;
  if (Array.isArray(content)) {
    return content
      .map((c) =>
        c && typeof c === 'object' && 'text' in c && typeof (c as { text?: unknown }).text === 'string'
          ? (c as { text: string }).text
          : '',
      )
      .join('');
  }
  return '';
}

/** Concatenate the `text` parts of an SDK message's content array. */
function joinTextParts(content: unknown): string {
  if (!Array.isArray(content)) return '';
  return content
    .map((part) => part as { type?: string; text?: string })
    .filter((p) => p.type === 'text' && typeof p.text === 'string')
    .map((p) => p.text as string)
    .join('');
}

/**
 * Translate ONE SDK message into zero or more provider events.
 *
 * Split out of `translateEvents` so the mapping is testable without standing
 * up the real SDK subprocess — the `activity` liveness event and the abort
 * check stay with the caller, since they're per-stream, not per-message.
 *
 * Takes `unknown` rather than the SDK's message union deliberately: every
 * branch already narrows structurally, and the union is a moving target
 * across SDK versions.
 */
export function translateSdkMessage(message: unknown): ProviderEvent[] {
  const m = message as { type?: string; subtype?: string };

  if (m.type === 'system' && m.subtype === 'init') {
    return [{ type: 'init', continuation: (message as { session_id: string }).session_id }];
  }

  if (m.type === 'assistant') {
    const content = (message as { message?: { content?: unknown[] } }).message?.content;

    // A harness failure — usage limit, auth, billing — is delivered as a
    // plain assistant message whose text reads exactly like the model wrote
    // it ("You've hit your limit · resets 9:50pm"). `error` is the only
    // discriminator (SDKAssistantMessage.error, sdk.d.ts) — the text is not
    // one, and must never be treated as one.
    //
    // Yielding it as `assistant_text` hands harness output to the poll-loop
    // as if the agent authored it: unwrapped by <message to="…">, so it gets
    // scratchpadded and dropped, then nudged for re-wrapping — a second turn
    // burned against the same limit, producing the same notice. Emit the
    // dedicated event so the poll-loop can deliver it and skip the nudge.
    const harnessError = (message as { error?: string }).error;
    if (harnessError) {
      // Content parts other than text (a tool_use) are deliberately dropped:
      // the turn failed, so no tool_result can ever pair with a
      // tool_use_start, and the orphan would suppress the idle watchdog.
      return [{ type: 'harness_error', code: harnessError, text: joinTextParts(content) }];
    }

    // Stream per-block assistant text so the poll-loop can dispatch
    // <message to="..."> blocks immediately, before the SDK reaches
    // its final `result` event. The SDK's `assistant` message carries
    // one or more content parts; we yield text parts as
    // `assistant_text` and tool_use parts as `tool_use_start` so the
    // poll-loop knows a tool is in flight and can suppress its idle
    // watchdog while it runs. Without that, a turn that emits text
    // then a long tool call (Bash, MCP, etc.) would either lose the
    // text on stall or get killed by the 2-min watchdog while the
    // tool was still doing real work.
    const events: ProviderEvent[] = [];
    if (Array.isArray(content)) {
      for (const part of content) {
        const p = part as { type?: string; text?: string; id?: string };
        if (p.type === 'text' && typeof p.text === 'string' && p.text.length > 0) {
          events.push({ type: 'assistant_text', text: p.text });
        } else if (p.type === 'tool_use' && typeof p.id === 'string' && p.id.length > 0) {
          events.push({ type: 'tool_use_start', id: p.id });
        }
      }
    }
    return events;
  }

  if (m.type === 'user') {
    // The SDK reports tool_result parts inside `user` messages — when
    // a tool returns, its result is fed back as user input for the
    // next model turn. Emit `tool_use_end` so the poll-loop can
    // remove the id from its in-flight set and let the idle watchdog
    // resume policing genuine SDK stalls.
    const content = (message as { message?: { content?: unknown[] } }).message?.content;
    const events: ProviderEvent[] = [];
    if (Array.isArray(content)) {
      for (const part of content) {
        const p = part as { type?: string; tool_use_id?: string; content?: unknown };
        if (p.type === 'tool_result' && typeof p.tool_use_id === 'string' && p.tool_use_id.length > 0) {
          events.push({ type: 'tool_use_end', id: p.tool_use_id, output: extractToolResultText(p.content) });
        }
      }
    }
    return events;
  }

  if (m.type === 'result') {
    const text = 'result' in (message as object) ? (message as { result?: string }).result ?? null : null;
    return [{ type: 'result', text }];
  }

  if (m.type === 'system' && m.subtype === 'api_retry') {
    return [{ type: 'error', message: 'API retry', retryable: true }];
  }

  // The SDK's dedicated rate-limit SYSTEM event. Note this is NOT the path a
  // usage limit takes — that arrives as an errored `assistant` message above.
  // Both exist; this one carries no reset time.
  if (m.type === 'system' && m.subtype === 'rate_limit_event') {
    return [{ type: 'error', message: 'Rate limit', retryable: false, classification: 'quota' }];
  }

  if (m.type === 'system' && m.subtype === 'compact_boundary') {
    const meta = (message as { compact_metadata?: { pre_tokens?: number } }).compact_metadata;
    const detail = meta?.pre_tokens ? ` (${meta.pre_tokens.toLocaleString()} tokens compacted)` : '';
    return [{ type: 'status_msg', text: `Context compacted${detail}`, level: 'info', kind: 'system' }];
  }

  if (m.type === 'system' && m.subtype === 'task_notification') {
    const tn = message as { summary?: string };
    return [{ type: 'progress', message: tn.summary || 'Task notification' }];
  }

  return [];
}

// Deferred SDK builtins that either sidestep nanoclaw's own scheduling or
// don't fit our async message-passing model (they're designed for Claude
// Code's interactive UI and would hang here).
//
// - CronCreate / CronDelete / CronList / ScheduleWakeup: we have durable
//   scheduling via mcp__nanoclaw__schedule_task.
// - AskUserQuestion: SDK returns a placeholder instead of blocking on a
//   real answer — we have mcp__nanoclaw__ask_user_question that persists
//   the question and blocks on the real reply.
// - EnterPlanMode / ExitPlanMode / EnterWorktree / ExitWorktree: Claude
//   Code UI affordances; in a headless container they'd appear stuck.
const SDK_DISALLOWED_TOOLS = [
  'CronCreate',
  'CronDelete',
  'CronList',
  'ScheduleWakeup',
  'AskUserQuestion',
  'EnterPlanMode',
  'ExitPlanMode',
  'EnterWorktree',
  'ExitWorktree',
];

// Tool allowlist for NanoClaw agent containers. MCP-tool entries are derived
// at the call site from the registered `mcpServers` map so that any server
// added via `add_mcp_server` (or wired in container.json directly) is
// reachable to the agent — without this, the SDK's allowedTools filter
// silently drops every MCP namespace not listed here.
const TOOL_ALLOWLIST = [
  'Bash',
  'Read',
  'Write',
  'Edit',
  'Glob',
  'Grep',
  'WebSearch',
  'WebFetch',
  'Task',
  'TaskOutput',
  'TaskStop',
  'TeamCreate',
  'TeamDelete',
  'SendMessage',
  'TodoWrite',
  'ToolSearch',
  'Skill',
  'NotebookEdit',
];

// MCP server names are sanitized by the SDK when forming tool prefixes:
// any character outside [A-Za-z0-9_-] becomes '_'. Mirror that here so our
// allowlist patterns match what the SDK actually exposes.
function mcpAllowPattern(serverName: string): string {
  return `mcp__${serverName.replace(/[^a-zA-Z0-9_-]/g, '_')}__*`;
}

interface SDKUserMessage {
  type: 'user';
  message: { role: 'user'; content: string };
  parent_tool_use_id: null;
  session_id: string;
}

/**
 * Push-based async iterable for streaming user messages to the Claude SDK.
 */
class MessageStream {
  private queue: SDKUserMessage[] = [];
  private waiting: (() => void) | null = null;
  private done = false;

  push(text: string): void {
    this.queue.push({
      type: 'user',
      message: { role: 'user', content: text },
      parent_tool_use_id: null,
      session_id: '',
    });
    this.waiting?.();
  }

  end(): void {
    this.done = true;
    this.waiting?.();
  }

  async *[Symbol.asyncIterator](): AsyncGenerator<SDKUserMessage> {
    while (true) {
      while (this.queue.length > 0) {
        yield this.queue.shift()!;
      }
      if (this.done) return;
      await new Promise<void>((r) => {
        this.waiting = r;
      });
      this.waiting = null;
    }
  }
}

// ── Transcript archiving (PreCompact hook) ──

interface ParsedMessage {
  role: 'user' | 'assistant';
  content: string;
}

function parseTranscript(content: string): ParsedMessage[] {
  const messages: ParsedMessage[] = [];
  for (const line of content.split('\n')) {
    if (!line.trim()) continue;
    try {
      const entry = JSON.parse(line);
      if (entry.type === 'user' && entry.message?.content) {
        const text = typeof entry.message.content === 'string' ? entry.message.content : entry.message.content.map((c: { text?: string }) => c.text || '').join('');
        if (text) messages.push({ role: 'user', content: text });
      } else if (entry.type === 'assistant' && entry.message?.content) {
        const textParts = entry.message.content.filter((c: { type: string }) => c.type === 'text').map((c: { text: string }) => c.text);
        const text = textParts.join('');
        if (text) messages.push({ role: 'assistant', content: text });
      }
    } catch {
      /* skip unparseable lines */
    }
  }
  return messages;
}

function formatTranscriptMarkdown(messages: ParsedMessage[], title?: string | null, assistantName?: string): string {
  const now = new Date();
  const dateStr = now.toLocaleString('en-US', { month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit', hour12: true });
  const lines = [`# ${title || 'Conversation'}`, '', `Archived: ${dateStr}`, '', '---', ''];
  for (const msg of messages) {
    const sender = msg.role === 'user' ? 'User' : assistantName || 'Assistant';
    const content = msg.content.length > 2000 ? msg.content.slice(0, 2000) + '...' : msg.content;
    lines.push(`**${sender}**: ${content}`, '');
  }
  return lines.join('\n');
}

/**
 * PreToolUse hook: record the current tool + its declared timeout so the host
 * sweep can widen its stuck tolerance while Bash is running a long-declared
 * script. Defense-in-depth: if SDK_DISALLOWED_TOOLS slips through somehow,
 * block the call here instead of letting the agent hang.
 */
const preToolUseHook: HookCallback = async (input) => {
  const i = input as { tool_name?: string; tool_input?: Record<string, unknown> };
  const toolName = i.tool_name ?? '';
  if (SDK_DISALLOWED_TOOLS.includes(toolName)) {
    return {
      decision: 'block',
      stopReason: `Tool '${toolName}' is not available in this environment — use the nanoclaw equivalent.`,
    } as unknown as ReturnType<HookCallback>;
  }
  // Bash exposes its timeout via the tool_input.timeout field (ms). Any other
  // tool: no declared timeout.
  const declaredTimeoutMs =
    toolName === 'Bash' && typeof i.tool_input?.timeout === 'number' ? (i.tool_input.timeout as number) : null;
  try {
    setContainerToolInFlight(toolName, declaredTimeoutMs);
  } catch (err) {
    log(`PreToolUse: failed to record container_state: ${err instanceof Error ? err.message : String(err)}`);
  }
  // Serialize shared-code writes across this agent's concurrent session containers
  // (skills/ and scripts/ are one RW mount shared by all of them). No-op for any
  // other write. Released in postToolUseHook.
  try {
    const locked = await lockForToolCall(toolName, i.tool_input);
    if (locked === false) log(`code-lock: ${toolName} proceeding unlocked (fail-open)`);
  } catch (err) {
    log(`PreToolUse: code-lock failed: ${err instanceof Error ? err.message : String(err)}`);
  }
  return { continue: true };
};

/** Clear in-flight tool + release any shared-code lock on PostToolUse / PostToolUseFailure. */
const postToolUseHook: HookCallback = async () => {
  try {
    unlockAfterToolCall();
  } catch (err) {
    log(`PostToolUse: code-lock release failed: ${err instanceof Error ? err.message : String(err)}`);
  }
  try {
    clearContainerToolInFlight();
  } catch (err) {
    log(`PostToolUse: failed to clear container_state: ${err instanceof Error ? err.message : String(err)}`);
  }
  return { continue: true };
};

function createPreCompactHook(assistantName?: string): HookCallback {
  return async (input) => {
    const preCompact = input as PreCompactHookInput;
    const { transcript_path: transcriptPath, session_id: sessionId } = preCompact;

    if (!transcriptPath || !fs.existsSync(transcriptPath)) {
      log('No transcript found for archiving');
      return {};
    }

    try {
      const content = fs.readFileSync(transcriptPath, 'utf-8');
      const messages = parseTranscript(content);
      if (messages.length === 0) return {};

      // Try to get summary from sessions index
      let summary: string | undefined;
      const indexPath = path.join(path.dirname(transcriptPath), 'sessions-index.json');
      if (fs.existsSync(indexPath)) {
        try {
          const index = JSON.parse(fs.readFileSync(indexPath, 'utf-8'));
          summary = index.entries?.find((e: { sessionId: string; summary?: string }) => e.sessionId === sessionId)?.summary;
        } catch {
          /* ignore */
        }
      }

      const name = summary
        ? summary.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '').slice(0, 50)
        : `conversation-${new Date().getHours().toString().padStart(2, '0')}${new Date().getMinutes().toString().padStart(2, '0')}`;

      const conversationsDir = '/workspace/agent/conversations';
      fs.mkdirSync(conversationsDir, { recursive: true });
      const filename = `${new Date().toISOString().split('T')[0]}-${name}.md`;
      fs.writeFileSync(path.join(conversationsDir, filename), formatTranscriptMarkdown(messages, summary, assistantName));
      log(`Archived conversation to ${filename}`);
    } catch (err) {
      log(`Failed to archive transcript: ${err instanceof Error ? err.message : String(err)}`);
    }
    return {};
  };
}

// ── Provider ──

/**
 * Claude Code auto-compacts context at this window (tokens). Kept here so
 * the generic bootstrap doesn't need to know about Claude-specific env vars.
 *
 * Operator override: set CLAUDE_CODE_AUTO_COMPACT_WINDOW in the host env to
 * raise or lower the threshold without editing source — useful when running
 * with a 1M-context model variant or when emergency-tuning a deployment.
 */
const CLAUDE_CODE_AUTO_COMPACT_WINDOW = process.env.CLAUDE_CODE_AUTO_COMPACT_WINDOW || '165000';

/**
 * Stale-session detection. Matches Claude Code's error text when a
 * resumed session can't be found — missing transcript .jsonl, unknown
 * session ID, etc.
 */
const STALE_SESSION_RE = /no conversation found|ENOENT.*\.jsonl|session.*not found/i;

export class ClaudeProvider implements AgentProvider {
  readonly supportsNativeSlashCommands = true;

  private assistantName?: string;
  private mcpServers: Record<string, McpServerConfig>;
  private env: Record<string, string | undefined>;
  private additionalDirectories?: string[];
  private model?: string;
  private effort?: string;

  constructor(options: ProviderOptions = {}) {
    this.assistantName = options.assistantName;
    this.mcpServers = options.mcpServers ?? {};
    this.additionalDirectories = options.additionalDirectories;
    this.model = options.model;
    this.effort = options.effort;
    this.env = {
      ...(options.env ?? {}),
      CLAUDE_CODE_AUTO_COMPACT_WINDOW,
    };
  }

  isSessionInvalid(err: unknown): boolean {
    const msg = err instanceof Error ? err.message : String(err);
    return STALE_SESSION_RE.test(msg);
  }

  query(input: QueryInput): AgentQuery {
    const stream = new MessageStream();
    stream.push(input.prompt);

    const instructions = input.systemContext?.instructions;

    const sdkResult = sdkQuery({
      prompt: stream,
      options: {
        cwd: input.cwd,
        additionalDirectories: this.additionalDirectories,
        resume: input.continuation,
        pathToClaudeCodeExecutable: '/pnpm/claude',
        systemPrompt: instructions ? { type: 'preset' as const, preset: 'claude_code' as const, append: instructions } : undefined,
        allowedTools: [
          ...TOOL_ALLOWLIST,
          ...Object.keys(this.mcpServers).map(mcpAllowPattern),
        ],
        disallowedTools: SDK_DISALLOWED_TOOLS,
        env: this.env,
        model: this.model,
        // eslint-disable-next-line @typescript-eslint/no-explicit-any
        effort: this.effort as any,
        permissionMode: 'bypassPermissions',
        allowDangerouslySkipPermissions: true,
        settingSources: ['project', 'user'],
        mcpServers: this.mcpServers,
        hooks: {
          PreToolUse: [{ hooks: [preToolUseHook] }],
          PostToolUse: [{ hooks: [postToolUseHook] }],
          PostToolUseFailure: [{ hooks: [postToolUseHook] }],
          PreCompact: [{ hooks: [createPreCompactHook(this.assistantName)] }],
        },
      },
    });

    let aborted = false;

    async function* translateEvents(): AsyncGenerator<ProviderEvent> {
      let messageCount = 0;
      for await (const message of sdkResult) {
        if (aborted) return;
        messageCount++;

        // Yield activity for every SDK event so the poll loop knows the agent is working
        yield { type: 'activity' };

        for (const event of translateSdkMessage(message)) yield event;
      }
      log(`Query completed after ${messageCount} SDK messages`);
    }

    return {
      push: (msg) => stream.push(msg),
      end: () => stream.end(),
      events: translateEvents(),
      abort: () => {
        aborted = true;
        stream.end();
      },
    };
  }
}

registerProvider('claude', (opts) => new ClaudeProvider(opts));
