import { describe, it, expect, beforeEach, afterEach } from 'bun:test';
import { mkdtempSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createHash } from 'node:crypto';

import { initTestSessionDb, closeSessionDb, getInboundDb, getOutboundDb } from './db/connection.js';
import { getPendingMessages, markCompleted, type MessageInRow } from './db/messages-in.js';
import { getUndeliveredMessages } from './db/messages-out.js';
import { formatMessages, extractRouting, type RoutingContext } from './formatter.js';
import {
  dispatchSystemReplies,
  partitionMessagesBySource,
  isAuthError,
  isWorkoutEventRow,
  serveImageRequests,
  dispatchResultText,
  dispatchCompleteBlocks,
  buildRejectNudge,
  processQuery,
} from './poll-loop.js';
import { MockProvider } from './providers/mock.js';
import type { AgentQuery, ProviderEvent } from './providers/types.js';
import { requestContextTool, onContextResponse } from './mcp-tools/request_context.js';

beforeEach(() => {
  initTestSessionDb();
});

afterEach(() => {
  closeSessionDb();
});

function insertMessage(
  id: string,
  kind: string,
  content: object,
  opts?: { processAfter?: string; trigger?: 0 | 1; onWake?: 0 | 1 },
) {
  getInboundDb()
    .prepare(
      `INSERT INTO messages_in (id, kind, timestamp, status, process_after, trigger, on_wake, content)
     VALUES (?, ?, datetime('now'), 'pending', ?, ?, ?, ?)`,
    )
    .run(id, kind, opts?.processAfter ?? null, opts?.trigger ?? 1, opts?.onWake ?? 0, JSON.stringify(content));
}

describe('formatter', () => {
  it('should format a single chat message', () => {
    insertMessage('m1', 'chat', { sender: 'John', text: 'Hello world' });
    const messages = getPendingMessages();
    const prompt = formatMessages(messages);
    expect(prompt).toContain('sender="John"');
    expect(prompt).toContain('Hello world');
  });

  it('should format multiple chat messages as XML block', () => {
    insertMessage('m1', 'chat', { sender: 'John', text: 'Hello' });
    insertMessage('m2', 'chat', { sender: 'Jane', text: 'Hi there' });
    const messages = getPendingMessages();
    const prompt = formatMessages(messages);
    expect(prompt).toContain('<messages>');
    expect(prompt).toContain('</messages>');
    expect(prompt).toContain('sender="John"');
    expect(prompt).toContain('sender="Jane"');
  });

  it('should format task messages', () => {
    insertMessage('m1', 'task', { prompt: 'Review open PRs' });
    const messages = getPendingMessages();
    const prompt = formatMessages(messages);
    expect(prompt).toContain('<task');
    expect(prompt).toContain('Review open PRs');
  });

  it('should format webhook messages', () => {
    insertMessage('m1', 'webhook', { source: 'github', event: 'push', payload: { ref: 'main' } });
    const messages = getPendingMessages();
    const prompt = formatMessages(messages);
    expect(prompt).toContain('<webhook');
    expect(prompt).toContain('source="github"');
    expect(prompt).toContain('event="push"');
  });

  it('should format system messages', () => {
    insertMessage('m1', 'system', { action: 'register_group', status: 'success', result: { id: 'ag-1' } });
    const messages = getPendingMessages();
    const prompt = formatMessages(messages);
    expect(prompt).toContain('<system_response');
    expect(prompt).toContain('action="register_group"');
  });

  it('should handle mixed kinds', () => {
    insertMessage('m1', 'chat', { sender: 'John', text: 'Hello' });
    insertMessage('m2', 'system', { action: 'test', status: 'ok', result: null });
    const messages = getPendingMessages();
    const prompt = formatMessages(messages);
    expect(prompt).toContain('sender="John"');
    expect(prompt).toContain('<system_response');
  });

  it('should escape XML in content', () => {
    insertMessage('m1', 'chat', { sender: 'A<B', text: 'x > y && z' });
    const messages = getPendingMessages();
    const prompt = formatMessages(messages);
    expect(prompt).toContain('A&lt;B');
    expect(prompt).toContain('x &gt; y &amp;&amp; z');
  });
});

describe('accumulate gate (trigger column)', () => {
  it('getPendingMessages returns both trigger=0 and trigger=1 rows', () => {
    // trigger=0 rides along as context, trigger=1 is the wake-eligible row.
    // The poll loop's gate depends on this data contract.
    insertMessage('m1', 'chat', { sender: 'A', text: 'chit chat' }, { trigger: 0 });
    insertMessage('m2', 'chat', { sender: 'B', text: 'actual mention' }, { trigger: 1 });
    const messages = getPendingMessages();
    expect(messages).toHaveLength(2);
    const byId = Object.fromEntries(messages.map((m) => [m.id, m]));
    expect(byId.m1.trigger).toBe(0);
    expect(byId.m2.trigger).toBe(1);
  });

  it('trigger=0-only batch: gate predicate `some(trigger===1)` is false', () => {
    insertMessage('m1', 'chat', { sender: 'A', text: 'noise' }, { trigger: 0 });
    insertMessage('m2', 'chat', { sender: 'B', text: 'more noise' }, { trigger: 0 });
    const messages = getPendingMessages();
    // This is the exact predicate the poll loop uses to skip accumulate-only
    // batches — gate should be false, so the loop sleeps without waking the agent.
    expect(messages.some((m) => m.trigger === 1)).toBe(false);
  });

  it('mixed batch: gate is true → loop proceeds, accumulated rows ride along', () => {
    insertMessage('m1', 'chat', { sender: 'A', text: 'earlier chatter' }, { trigger: 0 });
    insertMessage('m2', 'chat', { sender: 'B', text: 'the real mention' }, { trigger: 1 });
    const messages = getPendingMessages();
    expect(messages.some((m) => m.trigger === 1)).toBe(true);
    // Both messages are present for the formatter → agent sees the prior context.
    expect(messages.map((m) => m.id).sort()).toEqual(['m1', 'm2']);
  });

  it('trigger column defaults to 1 for legacy inserts without explicit value', () => {
    // The schema default is 1 (see src/db/schema.ts INBOUND_SCHEMA) — existing
    // rows / tests without the column set are effectively wake-eligible.
    getInboundDb()
      .prepare(
        `INSERT INTO messages_in (id, kind, timestamp, status, content)
         VALUES ('m1', 'chat', datetime('now'), 'pending', '{"text":"hi"}')`,
      )
      .run();
    const [msg] = getPendingMessages();
    expect(msg.trigger).toBe(1);
  });
});

describe('on_wake filtering', () => {
  it('first poll returns on_wake=1 messages', () => {
    insertMessage('m1', 'chat', { sender: 'system', text: 'Resuming.' }, { onWake: 1 });
    const messages = getPendingMessages(true);
    expect(messages).toHaveLength(1);
    expect(messages[0].id).toBe('m1');
  });

  it('subsequent polls skip on_wake=1 messages', () => {
    insertMessage('m1', 'chat', { sender: 'system', text: 'Resuming.' }, { onWake: 1 });
    const messages = getPendingMessages(false);
    expect(messages).toHaveLength(0);
  });

  it('normal messages returned regardless of isFirstPoll', () => {
    insertMessage('m1', 'chat', { sender: 'A', text: 'hello' });
    expect(getPendingMessages(true)).toHaveLength(1);

    // Reset: mark completed so we can re-test with a fresh message
    markCompleted(['m1']);
    insertMessage('m2', 'chat', { sender: 'A', text: 'hello again' });
    expect(getPendingMessages(false)).toHaveLength(1);
  });

  it('mixed batch: first poll returns both normal and on_wake messages', () => {
    insertMessage('m1', 'chat', { sender: 'A', text: 'user msg' });
    insertMessage('m2', 'chat', { sender: 'system', text: 'Resuming.' }, { onWake: 1 });
    const messages = getPendingMessages(true);
    expect(messages).toHaveLength(2);
    expect(messages.map((m) => m.id).sort()).toEqual(['m1', 'm2']);
  });

  it('mixed batch: subsequent poll returns only normal messages', () => {
    insertMessage('m1', 'chat', { sender: 'A', text: 'user msg' });
    insertMessage('m2', 'chat', { sender: 'system', text: 'Resuming.' }, { onWake: 1 });
    const messages = getPendingMessages(false);
    expect(messages).toHaveLength(1);
    expect(messages[0].id).toBe('m1');
  });

  it('on_wake defaults to 0 for inserts without explicit value', () => {
    getInboundDb()
      .prepare(
        `INSERT INTO messages_in (id, kind, timestamp, status, content)
         VALUES ('m1', 'chat', datetime('now'), 'pending', '{"text":"hi"}')`,
      )
      .run();
    // Should be returned even on non-first poll (on_wake=0)
    expect(getPendingMessages(false)).toHaveLength(1);
  });
});

describe('routing', () => {
  it('should extract routing from messages', () => {
    getInboundDb()
      .prepare(
        `INSERT INTO messages_in (id, kind, timestamp, status, platform_id, channel_type, thread_id, content)
       VALUES ('m1', 'chat', datetime('now'), 'pending', 'chan-123', 'discord', 'thread-456', '{"text":"hi"}')`,
      )
      .run();

    const messages = getPendingMessages();
    const routing = extractRouting(messages);
    expect(routing.platformId).toBe('chan-123');
    expect(routing.channelType).toBe('discord');
    expect(routing.threadId).toBe('thread-456');
    expect(routing.inReplyTo).toBe('m1');
  });
});

describe('origin metadata (from= attribute)', () => {
  function seedDestination(name: string, channelType: string, platformId: string): void {
    getInboundDb()
      .prepare(
        `INSERT INTO destinations (name, display_name, type, channel_type, platform_id, agent_group_id)
         VALUES (?, ?, 'channel', ?, ?, NULL)`,
      )
      .run(name, name, channelType, platformId);
  }

  function insertWithRouting(id: string, kind: string, content: object, channelType: string | null, platformId: string | null): void {
    getInboundDb()
      .prepare(
        `INSERT INTO messages_in (id, kind, timestamp, status, platform_id, channel_type, content)
         VALUES (?, ?, datetime('now'), 'pending', ?, ?, ?)`,
      )
      .run(id, kind, platformId, channelType, JSON.stringify(content));
  }

  it('chat message includes from= when destination matches', () => {
    seedDestination('discord-main', 'discord', 'chan-1');
    insertWithRouting('m1', 'chat', { sender: 'Alice', text: 'hi' }, 'discord', 'chan-1');
    const prompt = formatMessages(getPendingMessages());
    expect(prompt).toContain('from="discord-main"');
  });

  it('chat message falls back to raw routing when no destination matches', () => {
    insertWithRouting('m1', 'chat', { sender: 'Alice', text: 'hi' }, 'telegram', 'chat-999');
    const prompt = formatMessages(getPendingMessages());
    expect(prompt).toContain('from="unknown:telegram:chat-999"');
  });

  it('chat message omits from= when routing is null', () => {
    insertMessage('m1', 'chat', { sender: 'Alice', text: 'hi' });
    const prompt = formatMessages(getPendingMessages());
    expect(prompt).not.toContain('from=');
  });

  it('task message includes from= when destination matches', () => {
    seedDestination('slack-ops', 'slack', 'C-OPS');
    insertWithRouting('t1', 'task', { prompt: 'check status' }, 'slack', 'C-OPS');
    const prompt = formatMessages(getPendingMessages());
    expect(prompt).toContain('<task');
    expect(prompt).toContain('from="slack-ops"');
  });

  it('task message omits from= when routing is null', () => {
    insertMessage('t1', 'task', { prompt: 'check status' });
    const prompt = formatMessages(getPendingMessages());
    expect(prompt).toContain('<task');
    expect(prompt).not.toContain('from=');
  });

  it('webhook message includes from= when destination matches', () => {
    seedDestination('github-ch', 'github', 'repo-1');
    insertWithRouting('w1', 'webhook', { source: 'github', event: 'push', payload: {} }, 'github', 'repo-1');
    const prompt = formatMessages(getPendingMessages());
    expect(prompt).toContain('<webhook');
    expect(prompt).toContain('from="github-ch"');
  });

  it('system message includes from= when destination matches', () => {
    seedDestination('discord-main', 'discord', 'chan-1');
    insertWithRouting('s1', 'system', { action: 'test', status: 'ok', result: null }, 'discord', 'chan-1');
    const prompt = formatMessages(getPendingMessages());
    expect(prompt).toContain('<system_response');
    expect(prompt).toContain('from="discord-main"');
  });
});

describe('mock provider', () => {
  it('should produce init + result events', async () => {
    const provider = new MockProvider({}, (prompt) => `Echo: ${prompt}`);
    const query = provider.query({
      prompt: 'Hello',
      cwd: '/tmp',
    });

    const events: Array<{ type: string }> = [];
    setTimeout(() => query.end(), 50);

    for await (const event of query.events) {
      events.push(event);
    }

    const typed = events.filter((e) => e.type !== 'activity');
    expect(typed.length).toBeGreaterThanOrEqual(2);
    expect(typed[0].type).toBe('init');
    expect(typed[1].type).toBe('result');
    expect((typed[1] as { text: string }).text).toBe('Echo: Hello');
  });

  it('should handle push() during active query', async () => {
    const provider = new MockProvider({}, (prompt) => `Re: ${prompt}`);
    const query = provider.query({
      prompt: 'First',
      cwd: '/tmp',
    });

    const events: Array<{ type: string; text?: string }> = [];

    setTimeout(() => query.push('Second'), 30);
    setTimeout(() => query.end(), 60);

    for await (const event of query.events) {
      events.push(event);
    }

    const results = events.filter((e) => e.type === 'result');
    expect(results).toHaveLength(2);
    expect(results[0].text).toBe('Re: First');
    expect(results[1].text).toBe('Re: Second');
  });
});

describe('end-to-end with mock provider', () => {
  it('should read messages_in, process with mock provider, write messages_out', async () => {
    // Insert a chat message into inbound DB
    insertMessage('m1', 'chat', { sender: 'User', text: 'What is 2+2?' });

    // Read and process
    const messages = getPendingMessages();
    expect(messages).toHaveLength(1);

    const routing = extractRouting(messages);
    const prompt = formatMessages(messages);

    // Create mock provider and run query
    const provider = new MockProvider({}, () => 'The answer is 4');
    const query = provider.query({
      prompt,
      cwd: '/tmp',
    });

    // Process events — simulate what poll-loop does
    const { markProcessing } = await import('./db/messages-in.js');
    const { writeMessageOut } = await import('./db/messages-out.js');

    markProcessing(['m1']);

    setTimeout(() => query.end(), 50);

    for await (const event of query.events) {
      if (event.type === 'result' && event.text) {
        writeMessageOut({
          id: `out-${Date.now()}`,
          in_reply_to: routing.inReplyTo,
          kind: 'chat',
          platform_id: routing.platformId,
          channel_type: routing.channelType,
          thread_id: routing.threadId,
          content: JSON.stringify({ text: event.text }),
        });
      }
    }

    markCompleted(['m1']);

    // Verify: message was processed (not pending, acked in processing_ack)
    const processed = getPendingMessages();
    expect(processed).toHaveLength(0);

    // Verify: response was written to outbound DB
    const outMessages = getUndeliveredMessages();
    expect(outMessages).toHaveLength(1);
    expect(JSON.parse(outMessages[0].content).text).toBe('The answer is 4');
    expect(outMessages[0].in_reply_to).toBe('m1');
  });
});

describe('dispatchSystemReplies (ios-app context_response)', () => {
  it('consumes context_response rows and resolves the awaiting tool', async () => {
    // Stage 1: register a pending request via the tool. The tool writes
    // an envelope synchronously (we mock writeMessageOut to a no-op so
    // the bun:sqlite path isn't exercised) and returns a Promise we await.
    let requestId: string | null = null;
    const ctx = {
      session_id: 'sess-1',
      writeMessageOut: async (_sess: string, msg: { type: string; payload: Record<string, unknown> }) => {
        requestId = msg.payload.request_id as string;
      },
    };
    const pending = requestContextTool.handler({ fields: ['device'], timeout_ms: 5000 }, ctx as any);

    // Wait for the synchronous writeMessageOut microtask to flush.
    await new Promise((r) => setImmediate(r));
    expect(requestId).not.toBeNull();

    // Stage 2: simulate the host writing a `system` row carrying the
    // context_response. dispatchSystemReplies should consume it (returns
    // empty survivors) and resolve the tool's promise.
    const row = {
      id: 'sys-1',
      seq: 2,
      kind: 'system',
      timestamp: new Date().toISOString(),
      status: 'pending',
      process_after: null,
      recurrence: null,
      tries: 0,
      trigger: 1,
      platform_id: null,
      channel_type: null,
      thread_id: null,
      content: JSON.stringify({
        subtype: 'context_response',
        request_id: requestId,
        data: { device: { battery: 0.42 } },
      }),
    };
    const survivors = dispatchSystemReplies([row as any]);
    expect(survivors).toHaveLength(0);

    const result = await pending;
    expect(result).toEqual({ data: { device: { battery: 0.42 } }, errors: {} });
  });

  it('passes non-context_response system rows through unchanged', () => {
    const row = {
      id: 'sys-2',
      seq: 4,
      kind: 'system',
      timestamp: new Date().toISOString(),
      status: 'pending',
      process_after: null,
      recurrence: null,
      tries: 0,
      trigger: 1,
      platform_id: null,
      channel_type: null,
      thread_id: null,
      content: JSON.stringify({ action: 'something_else', status: 'ok', result: null }),
    };
    const survivors = dispatchSystemReplies([row as any]);
    expect(survivors).toHaveLength(1);
    expect(survivors[0].id).toBe('sys-2');
  });

  it('passes non-system rows through unchanged', () => {
    const row = {
      id: 'm-1',
      seq: 6,
      kind: 'chat',
      timestamp: new Date().toISOString(),
      status: 'pending',
      process_after: null,
      recurrence: null,
      tries: 0,
      trigger: 1,
      platform_id: null,
      channel_type: null,
      thread_id: null,
      content: JSON.stringify({ text: 'hi', sender: 'A' }),
    };
    const survivors = dispatchSystemReplies([row as any]);
    expect(survivors).toHaveLength(1);
    expect(survivors[0].kind).toBe('chat');
  });

  it('silently drops context_response for unknown request_id (late arrival)', () => {
    const row = {
      id: 'sys-3',
      seq: 8,
      kind: 'system',
      timestamp: new Date().toISOString(),
      status: 'pending',
      process_after: null,
      recurrence: null,
      tries: 0,
      trigger: 1,
      platform_id: null,
      channel_type: null,
      thread_id: null,
      content: JSON.stringify({
        subtype: 'context_response',
        request_id: 'never-existed',
        data: {},
      }),
    };
    // No exception thrown — onContextResponse is a no-op for unknown ids.
    const survivors = dispatchSystemReplies([row as any]);
    expect(survivors).toHaveLength(0);
  });

  // Reference unused imports so the import survives tree-shaking checks.
  it('onContextResponse export is callable', () => {
    expect(typeof onContextResponse).toBe('function');
  });
});

describe('isWorkoutEventRow (workout events reach the agent)', () => {
  const base = {
    id: 'x',
    seq: 1,
    timestamp: '2026-06-26T03:34:00Z',
    status: 'pending',
    process_after: null,
    recurrence: null,
    tries: 0,
    trigger: 1,
    platform_id: null,
    channel_type: null,
    thread_id: null,
    source_session_id: null,
  };

  it('true for a workout_event system row', () => {
    const row = { ...base, kind: 'system', content: JSON.stringify({ subtype: 'workout_event', event: 'workout_complete', payload: {} }) };
    expect(isWorkoutEventRow(row as MessageInRow)).toBe(true);
  });

  it('false for a context_response system row', () => {
    const row = { ...base, kind: 'system', content: JSON.stringify({ subtype: 'context_response', request_id: 'r' }) };
    expect(isWorkoutEventRow(row as MessageInRow)).toBe(false);
  });

  it('false for a chat row', () => {
    const row = { ...base, kind: 'chat', content: JSON.stringify({ text: 'hi' }) };
    expect(isWorkoutEventRow(row as MessageInRow)).toBe(false);
  });

  it('false for malformed system content', () => {
    const row = { ...base, kind: 'system', content: 'not json' };
    expect(isWorkoutEventRow(row as MessageInRow)).toBe(false);
  });

  it('the poll-loop system filter keeps workout_event but drops context_response', () => {
    const wk = { ...base, id: 'wk1', kind: 'system', content: JSON.stringify({ subtype: 'workout_event', event: 'workout_complete', payload: { workout_id: '2026-06-26' } }) };
    const ctx = { ...base, id: 'ctx1', kind: 'system', content: JSON.stringify({ subtype: 'context_response', request_id: 'never', data: {} }) };
    const chat = { ...base, id: 'c1', kind: 'chat', content: JSON.stringify({ text: 'hi' }) };
    const survivors = dispatchSystemReplies([wk, ctx, chat] as MessageInRow[]);
    // Mirror the exact filter expression the poll loop uses post-dispatch.
    const messages = survivors.filter((m) => m.kind !== 'system' || isWorkoutEventRow(m));
    const ids = messages.map((m) => m.id);
    expect(ids).toContain('wk1');
    expect(ids).toContain('c1');
    expect(ids).not.toContain('ctx1');
  });
});

describe('partitionMessagesBySource', () => {
  function makeRow(over: Partial<MessageInRow>): MessageInRow {
    return {
      id: 'm',
      seq: 1,
      kind: 'chat',
      timestamp: new Date().toISOString(),
      status: 'pending',
      process_after: null,
      recurrence: null,
      tries: 0,
      trigger: 1,
      platform_id: null,
      channel_type: null,
      thread_id: null,
      content: '',
      source_session_id: null,
      ...over,
    };
  }

  it('keeps a homogeneous channel-side batch in one partition', () => {
    const rows = [
      makeRow({ id: 'a', channel_type: 'telegram', platform_id: 'telegram:1' }),
      makeRow({ id: 'b', channel_type: 'telegram', platform_id: 'telegram:1' }),
    ];
    const parts = partitionMessagesBySource(rows);
    expect(parts).toHaveLength(1);
    expect(parts[0].map((m) => m.id)).toEqual(['a', 'b']);
  });

  it('splits two a2a inbound rows that come from different source sessions', () => {
    // The Greg-loop case: Jarvis-iOS a2a (older) + Jarvis-Tg a2a (newer)
    // both landed before the agent woke. Each must be its own provider call.
    const rows = [
      makeRow({
        id: 'a2a-ios',
        channel_type: 'agent',
        platform_id: 'ag-jarvis',
        source_session_id: 'sess-jarvis-ios',
      }),
      makeRow({
        id: 'a2a-tg',
        channel_type: 'agent',
        platform_id: 'ag-jarvis',
        source_session_id: 'sess-jarvis-tg',
      }),
    ];
    const parts = partitionMessagesBySource(rows);
    expect(parts).toHaveLength(2);
    // Order preserved — oldest source first, so the iOS group leads.
    expect(parts[0][0].id).toBe('a2a-ios');
    expect(parts[1][0].id).toBe('a2a-tg');
  });

  it('separates two telegram threads on the same channel', () => {
    const rows = [
      makeRow({ id: 'a', channel_type: 'telegram', platform_id: 'telegram:1', thread_id: 't1' }),
      makeRow({ id: 'b', channel_type: 'telegram', platform_id: 'telegram:1', thread_id: 't2' }),
    ];
    const parts = partitionMessagesBySource(rows);
    expect(parts).toHaveLength(2);
  });

  it('returns the empty list for an empty input', () => {
    expect(partitionMessagesBySource([])).toEqual([]);
  });
});

describe('isAuthError', () => {
  it('matches 401/403 and auth phrases', () => {
    for (const m of [
      'Request failed: 401 Unauthorized',
      'HTTP 403 Forbidden',
      'authentication_error: invalid x-api-key',
      'invalid api key',
      'oauth token expired',
      'token rejected by upstream',
    ]) {
      expect(isAuthError(m)).toBe(true);
    }
  });

  it('does not match unrelated errors', () => {
    for (const m of [
      'ECONNREFUSED 127.0.0.1:3002',
      'stream stalled — response cut short',
      'rate limit exceeded',
      'no conversation found',
    ]) {
      expect(isAuthError(m)).toBe(false);
    }
  });
});

describe('serveImageRequests', () => {
  let dir: string;
  beforeEach(() => {
    dir = mkdtempSync(join(tmpdir(), 'ex-'));
  });
  afterEach(() => {
    rmSync(dir, { recursive: true, force: true });
  });

  it('serves an image_blob for an existing file and consumes the request', () => {
    const bytes = Buffer.from([0x47, 0x49, 0x46, 0x38, 1, 2, 3]);
    writeFileSync(join(dir, 'zhim.gif'), bytes);
    insertMessage('ir1', 'system', { subtype: 'workout_event', event: 'image_request', payload: { slug: 'zhim' } });
    const survivors = serveImageRequests(getPendingMessages(), dir);
    expect(survivors.length).toBe(0);
    const out = getUndeliveredMessages();
    expect(out.length).toBe(1);
    const c = JSON.parse(out[0].content);
    expect(c.type).toBe('image_blob');
    expect(c.payload.slug).toBe('zhim');
    expect(c.payload.sha256).toBe(createHash('sha256').update(bytes).digest('hex'));
    expect(Buffer.from(c.payload.base64, 'base64')).toEqual(bytes);
  });

  it('prefers .gif over .jpg', () => {
    writeFileSync(join(dir, 'ex.jpg'), Buffer.from('JPGDATA'));
    writeFileSync(join(dir, 'ex.gif'), Buffer.from('GIF8DATA'));
    insertMessage('ir1', 'system', { subtype: 'workout_event', event: 'image_request', payload: { slug: 'ex' } });
    serveImageRequests(getPendingMessages(), dir);
    const c = JSON.parse(getUndeliveredMessages()[0].content);
    expect(Buffer.from(c.payload.base64, 'base64').toString()).toBe('GIF8DATA');
  });

  it('consumes but serves nothing when the file is missing', () => {
    insertMessage('ir1', 'system', { subtype: 'workout_event', event: 'image_request', payload: { slug: 'nope' } });
    const survivors = serveImageRequests(getPendingMessages(), dir);
    expect(survivors.length).toBe(0);
    expect(getUndeliveredMessages().length).toBe(0);
  });

  it('passes non-image_request workout events through untouched', () => {
    insertMessage('sl1', 'system', { subtype: 'workout_event', event: 'set_log', payload: {} });
    const survivors = serveImageRequests(getPendingMessages(), dir);
    expect(survivors.length).toBe(1);
    expect(getUndeliveredMessages().length).toBe(0);
  });
});

describe('a2a kind envelope (<message to="…" kind="…">)', () => {
  function seedAgentDest(name: string, agentGroupId: string): void {
    getInboundDb()
      .prepare(
        `INSERT INTO destinations (name, display_name, type, channel_type, platform_id, agent_group_id)
         VALUES (?, ?, 'agent', NULL, NULL, ?)`,
      )
      .run(name, name, agentGroupId);
  }

  function seedChannelDest(name: string, channelType: string, platformId: string): void {
    getInboundDb()
      .prepare(
        `INSERT INTO destinations (name, display_name, type, channel_type, platform_id, agent_group_id)
         VALUES (?, ?, 'channel', ?, ?, NULL)`,
      )
      .run(name, name, channelType, platformId);
  }

  const routing: RoutingContext = { platformId: null, channelType: null, threadId: null, inReplyTo: null };

  // Order by seq, NOT the timestamp `getUndeliveredMessages` sorts on:
  // `datetime('now')` has second granularity, so two sends inside one test tie
  // and "last" would be arbitrary. seq is unique and monotonic.
  function outRows(): Array<{ seq: number; content: string; channel_type: string | null; platform_id: string | null }> {
    return getOutboundDb()
      .prepare('SELECT seq, content, channel_type, platform_id FROM messages_out ORDER BY seq')
      .all() as Array<{ seq: number; content: string; channel_type: string | null; platform_id: string | null }>;
  }
  const outCount = (): number => outRows().length;
  const lastOut = () => outRows()[outRows().length - 1];

  beforeEach(() => {
    seedAgentDest('payne', 'ag-payne');
    seedChannelDest('family', 'telegram', 'tg-1');
  });

  it('lifts kind= into the outbound envelope for agent destinations', () => {
    dispatchResultText('<message to="payne" kind="set_log">{"reps":8}</message>', routing, new Set());
    expect(lastOut().content).toBe(JSON.stringify({ text: '{"reps":8}', a2a_kind: 'set_log' }));
  });

  it('defaults an omitted kind to text for agent destinations', () => {
    dispatchResultText('<message to="payne">норм</message>', routing, new Set());
    expect(lastOut().content).toBe(JSON.stringify({ text: 'норм', a2a_kind: 'text' }));
  });

  it('never writes kind for channel destinations', () => {
    dispatchResultText('<message to="family">Ужин в 8</message>', routing, new Set());
    expect(lastOut().content).toBe(JSON.stringify({ text: 'Ужин в 8' }));
  });

  it('never writes kind for channel destinations even when the agent supplies one', () => {
    // kind is an a2a concept. A channel adapter would render the JSON blob
    // verbatim, so a stray kind= must be dropped, not carried through.
    dispatchResultText('<message to="family" kind="set_log">Ужин в 8</message>', routing, new Set());
    expect(lastOut().content).toBe(JSON.stringify({ text: 'Ужин в 8' }));
  });

  it('accepts kind= before to=', () => {
    dispatchResultText('<message kind="ack" to="payne">ок</message>', routing, new Set());
    expect(lastOut().content).toBe(JSON.stringify({ text: 'ок', a2a_kind: 'ack' }));
  });

  it('routes an agent block to the target agent group, not a channel', () => {
    dispatchResultText('<message to="payne" kind="ack">ок</message>', routing, new Set());
    expect(lastOut().channel_type).toBe('agent');
    expect(lastOut().platform_id).toBe('ag-payne');
  });

  it('still ignores a <message> with no to= so the no-wrap nudge survives', () => {
    const r = dispatchResultText('<message kind="set_log">{"a":1}</message>', routing, new Set());
    expect(r.newlySent).toBe(0);
    expect(r.hasUnwrapped).toBe(true);
    expect(outCount()).toBe(0);
  });

  it('treats same body with different kind as different messages', () => {
    const dispatched = new Set<string>();
    dispatchResultText('<message to="payne" kind="set_log">{}</message>', routing, dispatched);
    dispatchResultText('<message to="payne" kind="ack">{}</message>', routing, dispatched);
    expect(outCount()).toBe(2);
  });

  it('still dedupes an identical (to, kind, body) triple', () => {
    const dispatched = new Set<string>();
    dispatchResultText('<message to="payne" kind="set_log">{}</message>', routing, dispatched);
    dispatchResultText('<message to="payne" kind="set_log">{}</message>', routing, dispatched);
    expect(outCount()).toBe(1);
  });

  it('drops a block addressed to an unknown destination', () => {
    const r = dispatchResultText('<message to="nobody" kind="ack">x</message>', routing, new Set());
    expect(r.newlySent).toBe(0);
    expect(outCount()).toBe(0);
    // A block WAS present, so this is not the unwrapped case.
    expect(r.hasUnwrapped).toBe(false);
  });

  it('streaming path lifts kind= and returns the unconsumed tail', () => {
    const { remainder } = dispatchCompleteBlocks(
      '<message to="payne" kind="set_log">{"reps":8}</message>trailing',
      routing,
      new Set(),
    );
    expect(lastOut().content).toBe(JSON.stringify({ text: '{"reps":8}', a2a_kind: 'set_log' }));
    expect(remainder).toBe('trailing');
  });

  it('streaming and result paths share dedupe keys — no double send', () => {
    // The poll loop hands the same Set to both. If the two paths built keys
    // differently, the result pass would re-send what streaming already sent.
    const dispatched = new Set<string>();
    const block = '<message to="payne" kind="set_log">{"reps":8}</message>';
    dispatchCompleteBlocks(block, routing, dispatched);
    const r = dispatchResultText(block, routing, dispatched);
    expect(r.newlySent).toBe(0);
    expect(outCount()).toBe(1);
  });
});

/**
 * Layer 1 of the a2a kind gate: an illegal block is never written to
 * messages_out, and the reject comes back so the caller can nudge the agent
 * in the same turn.
 *
 * The `a2a_kinds` column is what arms it. Every destination the host writes
 * today has it NULL (no agent.json exists yet), so these tests seed it by hand
 * to reach the armed branch at all — see the disarm test for the inert case.
 */
describe('a2a kind gate (layer 1 — container)', () => {
  /** Seed an agent destination, arming the gate when `kinds` is non-null. */
  function seedAgentDest(name: string, agentGroupId: string, kinds: string[] | null): void {
    getInboundDb()
      .prepare(
        `INSERT INTO destinations (name, display_name, type, channel_type, platform_id, agent_group_id, a2a_kinds)
         VALUES (?, ?, 'agent', NULL, NULL, ?, ?)`,
      )
      .run(name, name, agentGroupId, kinds === null ? null : JSON.stringify(kinds));
  }

  const routing: RoutingContext = { platformId: null, channelType: null, threadId: null, inReplyTo: null };
  const outCount = (): number =>
    (getOutboundDb().prepare('SELECT COUNT(*) AS n FROM messages_out').get() as { n: number }).n;

  describe('armed target (descriptor declares set_log)', () => {
    beforeEach(() => {
      seedAgentDest('payne', 'ag-payne', ['set_log']);
    });

    it('does not emit a block whose kind is undeclared', () => {
      const r = dispatchResultText('<message to="payne" kind="bogus">x</message>', routing, new Set());
      expect(outCount()).toBe(0);
      expect(r.newlySent).toBe(0);
    });

    it('reports an undeclared kind as a reject for the caller to nudge', () => {
      const r = dispatchResultText('<message to="payne" kind="bogus">x</message>', routing, new Set());
      expect(r.rejects).toEqual([{ to: 'payne', kind: 'bogus', code: 'unknown_kind', legal: ['set_log'] }]);
    });

    it('still emits a declared kind', () => {
      // Guards the inverse mutation: a gate that rejects everything once armed
      // would pass the test above and silence the agent entirely.
      const r = dispatchResultText('<message to="payne" kind="set_log">{"reps":8}</message>', routing, new Set());
      expect(outCount()).toBe(1);
      expect(r.rejects).toEqual([]);
    });

    it('does not emit a JSON-object body sent with no kind=', () => {
      // The forgotten-attribute case: a structured payload must not sail
      // through as prose.
      const r = dispatchResultText('<message to="payne">{"reps":8}</message>', routing, new Set());
      expect(outCount()).toBe(0);
      expect(r.rejects).toEqual([{ to: 'payne', kind: null, code: 'unmarked_json', legal: ['set_log'] }]);
    });

    it('still emits prose sent with no kind=', () => {
      // `text` is legal without being declared. Without this, the test above
      // would also pass a gate that bounced every kind-less block.
      const r = dispatchResultText('<message to="payne">норм</message>', routing, new Set());
      expect(outCount()).toBe(1);
      expect(r.rejects).toEqual([]);
    });

    it('gates the streaming path too, and still returns the unconsumed tail', () => {
      const { remainder, rejects } = dispatchCompleteBlocks(
        '<message to="payne" kind="bogus">x</message>trailing',
        routing,
        new Set(),
      );
      expect(outCount()).toBe(0);
      expect(rejects).toEqual([{ to: 'payne', kind: 'bogus', code: 'unknown_kind', legal: ['set_log'] }]);
      expect(remainder).toBe('trailing');
    });

    it('reports every rejected block in one turn, not just the first', () => {
      const r = dispatchResultText(
        '<message to="payne" kind="bogus">x</message><message to="payne" kind="worse">y</message>',
        routing,
        new Set(),
      );
      expect(outCount()).toBe(0);
      expect(r.rejects.map((x) => x.kind)).toEqual(['bogus', 'worse']);
    });
  });

  it('emits normally when the target has no descriptor (gate disarmed)', () => {
    // SHIP-INERT. This is the state of every agent in the wild right now:
    // a2a_kinds NULL → legalKinds null → nothing is gated.
    //
    // Honest note on killability: deleting the gate entirely would NOT fail
    // this test. It exists to kill a different, specific mutation —
    // `dest.a2aKinds ?? []` in place of `?? null`, which would arm every
    // un-migrated agent and bounce all live structured traffic. Verified by
    // running that mutation against this test.
    seedAgentDest('payne', 'ag-payne', null);
    const r = dispatchResultText('<message to="payne" kind="anything">{"reps":8}</message>', routing, new Set());
    expect(outCount()).toBe(1);
    expect(r.rejects).toEqual([]);
  });

  it('emits normally when the target declares no kinds but the body is prose', () => {
    // `[]` is NOT null: descriptor present, declares nothing → text-only, ARMED.
    seedAgentDest('greg', 'ag-greg', []);
    const r = dispatchResultText('<message to="greg">как дела</message>', routing, new Set());
    expect(outCount()).toBe(1);
    expect(r.rejects).toEqual([]);
  });

  it('bounces a declared-nothing target when the body is structured', () => {
    // The `[]`-arms-text-only contract, from the other side.
    seedAgentDest('greg', 'ag-greg', []);
    const r = dispatchResultText('<message to="greg" kind="set_log">{}</message>', routing, new Set());
    expect(outCount()).toBe(0);
    expect(r.rejects).toEqual([{ to: 'greg', kind: 'set_log', code: 'unknown_kind', legal: [] }]);
  });

  it('never gates a channel destination, even one carrying kinds', () => {
    // The host writes a2a_kinds NULL for every channel row, so the
    // `type === 'agent'` guard is currently belt-and-braces. This seeds the
    // unreal state on purpose: it is the only way to prove the guard is what
    // keeps channels out of the gate, and it pins the invariant against a
    // future projection change that starts writing kinds onto channel rows —
    // which without the guard would bounce every JSON-bodied channel message.
    getInboundDb()
      .prepare(
        `INSERT INTO destinations (name, display_name, type, channel_type, platform_id, agent_group_id, a2a_kinds)
         VALUES ('family', 'family', 'channel', 'telegram', 'tg-1', NULL, '["set_log"]')`,
      )
      .run();
    const r = dispatchResultText('<message to="family">{"raw":"json"}</message>', routing, new Set());
    expect(outCount()).toBe(1);
    expect(r.rejects).toEqual([]);
  });

  it('reports an unknown destination as a reject instead of dropping it silently', () => {
    const r = dispatchResultText('<message to="nobody" kind="ack">x</message>', routing, new Set());
    expect(outCount()).toBe(0);
    expect(r.rejects).toEqual([{ to: 'nobody', kind: 'ack', code: 'unknown_destination' }]);
  });

  it('reports an unknown destination from the streaming path too', () => {
    const { rejects } = dispatchCompleteBlocks('<message to="nobody">x</message>', routing, new Set());
    expect(rejects).toEqual([{ to: 'nobody', kind: null, code: 'unknown_destination' }]);
  });
});

describe('buildRejectNudge', () => {
  it('names the destination, the offending kind, and the legal list', () => {
    const nudge = buildRejectNudge([{ to: 'payne', kind: 'bogus', code: 'unknown_kind', legal: ['set_log', 'ack'] }]);
    expect(nudge).toContain('to="payne"');
    expect(nudge).toContain('kind="bogus"');
    // `text` is always legal and never declared, so it is appended, not stored.
    expect(nudge).toContain('set_log, ack, text');
  });

  it('tells the agent a structured body needs a kind', () => {
    const nudge = buildRejectNudge([{ to: 'payne', kind: null, code: 'unmarked_json', legal: ['set_log'] }]);
    expect(nudge).toContain('to="payne"');
    expect(nudge).toContain('kind=');
    expect(nudge).not.toContain('Легальные:'); // an unmarked body has no kind to list against
  });

  it('says the destination does not exist for an unknown-destination reject', () => {
    const nudge = buildRejectNudge([{ to: 'nobody', kind: null, code: 'unknown_destination' }]);
    expect(nudge).toContain('to="nobody"');
    expect(nudge).toContain('нет');
  });

  it('describes every reject in a single nudge', () => {
    const nudge = buildRejectNudge([
      { to: 'payne', kind: 'bogus', code: 'unknown_kind', legal: ['set_log'] },
      { to: 'nobody', kind: null, code: 'unknown_destination' },
    ]);
    expect(nudge).toContain('to="payne"');
    expect(nudge).toContain('to="nobody"');
    // One <system> wrapper for the whole turn, not one per reject.
    expect(nudge.match(/<system>/g)).toHaveLength(1);
  });

  it('degrades to text-only when a kind reject carries no legal list', () => {
    const nudge = buildRejectNudge([{ to: 'payne', kind: 'bogus', code: 'unknown_kind' }]);
    expect(nudge).toContain('Легальные: text.');
  });
});

/**
 * `turnRejects` is turn-scoped: the streaming path accumulates rejects across a
 * turn's many assistant_text events so that ONE nudge at `result` covers them
 * all. That makes clearing it at every turn boundary load-bearing — a reject
 * that outlives its turn gets reported against someone else's output.
 *
 * Driven through `processQuery` with a hand-rolled AgentQuery: the accumulator
 * is a local, so the exported dispatch helpers cannot reach it.
 */
describe('processQuery turn-scoped rejects', () => {
  const routing: RoutingContext = { platformId: null, channelType: null, threadId: null, inReplyTo: null };

  function seedAgentDest(name: string, agentGroupId: string): void {
    getInboundDb()
      .prepare(
        `INSERT INTO destinations (name, display_name, type, channel_type, platform_id, agent_group_id)
         VALUES (?, ?, 'agent', NULL, NULL, ?)`,
      )
      .run(name, name, agentGroupId);
  }

  /** Replays a canned event script and records everything pushed back in. */
  function fakeQuery(events: ProviderEvent[]): { query: AgentQuery; pushes: string[] } {
    const pushes: string[] = [];
    return {
      pushes,
      query: {
        push: (message: string) => {
          pushes.push(message);
        },
        end: () => {},
        abort: () => {},
        events: {
          async *[Symbol.asyncIterator]() {
            for (const e of events) yield e;
          },
        },
      },
    };
  }

  it('does not report a previous turn reject in this turn nudge (result with no text)', async () => {
    // REGRESSION. providers/claude.ts yields `text: null` for error_max_turns
    // and error_during_execution, and the flush lived inside `if (event.text)`.
    // So turn 1's reject was never cleared, and turn 2 — whose own output was
    // fine — got nudged to re-send a block IT never wrote, to a destination it
    // never named. Reachable without any descriptor: unknown_destination.
    seedAgentDest('payne', 'ag-payne');
    const { query, pushes } = fakeQuery([
      { type: 'init', continuation: 'c1' },
      { type: 'assistant_text', text: '<message to="nobody">x</message>' },
      { type: 'result', text: null },
      { type: 'assistant_text', text: '<message to="payne">ок</message>' },
      { type: 'result', text: '<message to="payne">ок</message>' },
    ]);

    await processQuery(query, routing, [], 'mock');

    expect(pushes.join('\n')).not.toContain('nobody');
  });

  it('still nudges for a block rejected in the same turn', async () => {
    // Inverse-mutation guard: clearing turnRejects before the flush instead of
    // after would pass the test above while silently killing the nudge.
    const { query, pushes } = fakeQuery([
      { type: 'init', continuation: 'c1' },
      { type: 'assistant_text', text: '<message to="nobody">x</message>' },
      { type: 'result', text: '<message to="nobody">x</message>' },
    ]);

    await processQuery(query, routing, [], 'mock');

    expect(pushes.join('\n')).toContain('nobody');
  });
});

/**
 * A usage limit reaches the poll-loop as harness output wearing the agent's
 * voice. Production, jarvis mid-cron (logs/containers.log):
 *
 *   [poll-loop] Assistant text (53 chars): You've hit your limit · resets 9:50pm
 *   [poll-loop] [scratchpad] You've hit your limit · resets 9:50pm
 *   [poll-loop] WARNING: agent output had no <message to="..."> blocks — nothing was sent
 *   …identical block again — the nudge burned a second turn against the limit…
 *   [poll-loop] Completed 1 message(s)
 *
 * The owner was told nothing. The wrap rule — built to stop the agent leaking
 * scratchpad — silenced a notice the agent never wrote and could not re-wrap.
 *
 * Delivery needs no API call (container writes messages_out, host delivers), so
 * a rate-limited agent can still report. These drive `processQuery` with the
 * `harness_error` event providers/claude.ts now yields for it.
 */
describe('processQuery — harness errors', () => {
  const LIMIT_TEXT = "You've hit your limit · resets 9:50pm (Asia/Makassar)";
  const routing: RoutingContext = { platformId: null, channelType: null, threadId: null, inReplyTo: null };

  function fakeQuery(events: ProviderEvent[]): { query: AgentQuery; pushes: string[] } {
    const pushes: string[] = [];
    return {
      pushes,
      query: {
        push: (message: string) => {
          pushes.push(message);
        },
        end: () => {},
        abort: () => {},
        events: {
          async *[Symbol.asyncIterator]() {
            for (const e of events) yield e;
          },
        },
      },
    };
  }

  function seedChannelDest(name: string, channelType: string, platformId: string): void {
    getInboundDb()
      .prepare(
        `INSERT INTO destinations (name, display_name, type, channel_type, platform_id, agent_group_id)
         VALUES (?, ?, 'channel', ?, ?, NULL)`,
      )
      .run(name, name, channelType, platformId);
  }

  function seedSessionRouting(channelType: string, platformId: string, threadId: string | null): void {
    getInboundDb()
      .prepare(`INSERT INTO session_routing (id, channel_type, platform_id, thread_id) VALUES (1, ?, ?, ?)`)
      .run(channelType, platformId, threadId);
  }

  /** The exact production shape: harness error, then a result echoing its text. */
  function limitTurn(): ProviderEvent[] {
    return [
      { type: 'init', continuation: 'c1' },
      { type: 'harness_error', code: 'rate_limit', text: LIMIT_TEXT },
      { type: 'result', text: LIMIT_TEXT },
    ];
  }

  it('delivers the notice with the SDK text verbatim', async () => {
    seedChannelDest('casa', 'telegram', 'chat-1');
    const { query } = fakeQuery(limitTurn());

    await processQuery(query, routing, [], 'mock');

    const rows = getUndeliveredMessages();
    expect(rows).toHaveLength(1);
    const content = JSON.parse(rows[0].content);
    // Verbatim: the reset time exists nowhere else — not in the code, not in
    // any other event. Truncating or paraphrasing it loses the only fact the
    // owner needs.
    expect(content.text).toContain(LIMIT_TEXT);
    expect(rows[0].kind).toBe('chat');
  });

  it('marks the notice as not-the-agent-speaking', async () => {
    seedChannelDest('casa', 'telegram', 'chat-1');
    const { query } = fakeQuery(limitTurn());

    await processQuery(query, routing, [], 'mock');

    const content = JSON.parse(getUndeliveredMessages()[0].content);
    // `sender: 'system'` is the established marker for host/harness-authored
    // content (container-restart.ts, approvals/primitive.ts). It also carries
    // real weight: the host's a2a gate passes system notes unconditionally
    // (agent-route.ts checkA2aKind) and stampSenderIdentity won't overwrite it
    // with the sending agent's name.
    expect(content.sender).toBe('system');
    // And visibly so, for a human reading the chat.
    expect(content.text).not.toBe(LIMIT_TEXT);
    expect(content.text.toLowerCase()).toContain('system notice');
  });

  it('delivers as user-facing, not a status ping', async () => {
    // Status rows are excluded by isUserFacing (messages-out.ts) and never
    // reach the owner. The whole bug is the owner not being told.
    seedChannelDest('casa', 'telegram', 'chat-1');
    const { query } = fakeQuery(limitTurn());

    await processQuery(query, routing, [], 'mock');

    expect(getUndeliveredMessages()[0].content).not.toContain('"type":"status"');
  });

  it('does NOT nudge the agent to re-wrap a notice it never wrote', async () => {
    // THE burned-turn bug. The nudge cannot help: the agent did not author the
    // text, cannot re-wrap it, and is rate-limited — so the "retry" spends a
    // second turn against the same limit and reproduces the same notice.
    seedChannelDest('casa', 'telegram', 'chat-1');
    const { query, pushes } = fakeQuery(limitTurn());

    await processQuery(query, routing, [], 'mock');

    expect(pushes).toHaveLength(0);
  });

  it('REGRESSION: still nudges a normal unwrapped-text turn', async () => {
    // The guard this fix must not break: real agent scratchpad with no
    // <message to=> wrapper still gets the nudge.
    seedChannelDest('casa', 'telegram', 'chat-1');
    const { query, pushes } = fakeQuery([
      { type: 'init', continuation: 'c1' },
      { type: 'result', text: 'я просто думаю вслух' },
    ]);

    await processQuery(query, routing, [], 'mock');

    expect(pushes.join('\n')).toContain('not wrapped');
  });

  it('re-arms the nudge on a later turn — suppression is turn-scoped', async () => {
    // Inverse-mutation guard: a query-scoped flag would pass every test above
    // while silently disabling the no-wrap nudge for the rest of the query.
    seedChannelDest('casa', 'telegram', 'chat-1');
    const { query, pushes } = fakeQuery([
      { type: 'init', continuation: 'c1' },
      { type: 'harness_error', code: 'rate_limit', text: LIMIT_TEXT },
      { type: 'result', text: LIMIT_TEXT },
      // A later turn, agent back on its feet, genuinely unwrapped output.
      { type: 'result', text: 'опять забыл обернуть' },
    ]);

    await processQuery(query, routing, [], 'mock');

    expect(pushes.join('\n')).toContain('not wrapped');
  });

  it('addresses the notice by session routing when the batch has none', async () => {
    // The cron case: the task row carries no channel/platform, so `routing` is
    // all-null and the existing writes here would produce an unaddressed row.
    seedSessionRouting('telegram', 'chat-99', 'thread-7');
    seedChannelDest('casa', 'whatsapp', 'group-1@g.us');
    const { query } = fakeQuery(limitTurn());

    await processQuery(query, routing, [], 'mock');

    const row = getUndeliveredMessages()[0];
    expect(row.channel_type).toBe('telegram');
    expect(row.platform_id).toBe('chat-99');
    expect(row.thread_id).toBe('thread-7');
  });

  it('falls back to the sole destination for a headless session', async () => {
    seedChannelDest('casa', 'whatsapp', 'group-1@g.us');
    const { query } = fakeQuery(limitTurn());

    await processQuery(query, routing, [], 'mock');

    const row = getUndeliveredMessages()[0];
    expect(row.channel_type).toBe('whatsapp');
    expect(row.platform_id).toBe('group-1@g.us');
  });

  it('drops the notice without throwing when nothing resolves', async () => {
    // No destinations, no session routing. Must not kill the turn: the batch
    // still needs its markCompleted, and an exception here would strand it.
    const { query } = fakeQuery(limitTurn());

    await expect(processQuery(query, routing, [], 'mock')).resolves.toBeDefined();
    expect(getUndeliveredMessages()).toHaveLength(0);
  });

  it('does not nudge even when the notice could not be delivered', async () => {
    // Suppression must not depend on delivery succeeding — an undeliverable
    // notice is still not the agent's text to re-wrap.
    const { query, pushes } = fakeQuery(limitTurn());

    await processQuery(query, routing, [], 'mock');

    expect(pushes).toHaveLength(0);
  });
});
