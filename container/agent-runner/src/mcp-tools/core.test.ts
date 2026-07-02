/**
 * Tests for the core MCP tools' interaction with the per-batch routing
 * context. The agent-runner sets a current `inReplyTo` at the top of each
 * batch in poll-loop, and outbound writes from MCP tools (send_message,
 * send_file) must pick it up so a2a return-path routing on the host can
 * correlate replies back to the originating session.
 */
import { describe, it, expect, beforeEach, afterEach } from 'bun:test';

import { initTestSessionDb, closeSessionDb, getInboundDb, getOutboundDb } from '../db/connection.js';
import { getCurrentOutboundTextBySeq, getUndeliveredMessages, writeMessageOut } from '../db/messages-out.js';
import { setCurrentInReplyTo, clearCurrentInReplyTo } from '../current-batch.js';
import { sendMessage, editMessage } from './core.js';

beforeEach(() => {
  initTestSessionDb();
  // Seed a peer agent destination
  getInboundDb()
    .prepare(
      `INSERT INTO destinations (name, display_name, type, channel_type, platform_id, agent_group_id)
       VALUES ('peer', 'Peer', 'agent', NULL, NULL, 'ag-peer')`,
    )
    .run();
});

afterEach(() => {
  clearCurrentInReplyTo();
  closeSessionDb();
});

describe('send_message MCP tool — in_reply_to plumbing', () => {
  it('stamps current batch in_reply_to on outbound rows', async () => {
    setCurrentInReplyTo('inbound-msg-1');

    await sendMessage.handler({ to: 'peer', text: 'hello' });

    const out = getUndeliveredMessages();
    expect(out).toHaveLength(1);
    expect(out[0].in_reply_to).toBe('inbound-msg-1');
  });

  it('writes null when no batch is active', async () => {
    // No setCurrentInReplyTo before this call — simulates ad-hoc / out-of-batch invocation.
    await sendMessage.handler({ to: 'peer', text: 'hello' });

    const out = getUndeliveredMessages();
    expect(out).toHaveLength(1);
    expect(out[0].in_reply_to).toBeNull();
  });
});

describe('edit_message targeting', () => {
  it('errors when text is missing', async () => {
    const res = await editMessage.handler({ messageId: 1 });
    expect(res.isError).toBe(true);
  });

  it('errors with a clear message when messageId is non-numeric', async () => {
    const res = await editMessage.handler({ messageId: '867B-not-a-seq', text: 'x' });
    expect(res.isError).toBe(true);
    expect(res.content[0].text).toContain('numeric');
  });

  it('edits the last user-facing message when messageId is omitted', async () => {
    const seq = writeMessageOut({
      id: 'm1', kind: 'chat', platform_id: 'p', channel_type: 'ios-app-v2',
      thread_id: null, content: JSON.stringify({ text: 'oops' }),
    });
    const res = await editMessage.handler({ text: 'corrected' });
    expect(res.isError).toBeUndefined();
    expect(res.content[0].text).toContain(String(seq));
    // Verify the edit was actually written to outbound (not just the string echo).
    const edit = getUndeliveredMessages().find((m) => JSON.parse(m.content).operation === 'edit');
    expect(edit).toBeTruthy();
    expect(JSON.parse(edit!.content).text).toBe('corrected');
  });

  it('errors when omitted and there is no prior message', async () => {
    const res = await editMessage.handler({ text: 'corrected' });
    expect(res.isError).toBe(true);
  });

  it('refuses to edit a seq that is not the agent\'s own outbound message', async () => {
    const mine = writeMessageOut({
      id: 'mine', kind: 'chat', platform_id: 'p', channel_type: 'ios-app-v2',
      thread_id: null, content: JSON.stringify({ text: 'mine' }),
    });
    // A seq not present in messages_out (e.g. a user/inbound message id) must be refused.
    const res = await editMessage.handler({ messageId: mine + 1, text: 'hijack' });
    expect(res.isError).toBe(true);
    expect(res.content[0].text).toContain("isn't a message you sent");
  });

  it('refuses an edit that replaces most of the message (delivering new content)', async () => {
    const seq = writeMessageOut({
      id: 'orig', kind: 'chat', platform_id: 'p', channel_type: 'ios-app-v2',
      thread_id: null,
      content: JSON.stringify({ text: 'Контекст сброшен. Начинаем с чистого листа.' }),
    });
    const res = await editMessage.handler({
      messageId: seq,
      text:
        'Балансы на 1 июля: SafePal earn 855.16$, SafePal wallet 66.65$, ' +
        'Telegram wallet 1712$, Bybit 340$, итого около 2973$ по кошелькам.',
    });
    expect(res.isError).toBe(true);
    expect(res.content[0].text).toContain('send_message');
    // No edit was queued — the replacement was refused, not written.
    const edit = getUndeliveredMessages().find((m) => JSON.parse(m.content).operation === 'edit');
    expect(edit).toBeUndefined();
  });

  it('compares a re-edit against the CURRENT text, not the frozen original', async () => {
    // A sequence of small corrections to the same bubble must not accumulate
    // past the replacement threshold: the baseline is what the user sees NOW
    // (original + latest edit), not the original text that was long since fixed.
    const original = 'a'.repeat(50);
    const seq = writeMessageOut({
      id: 'orig', kind: 'chat', platform_id: 'p', channel_type: 'ios-app-v2',
      thread_id: null, content: JSON.stringify({ text: original }),
    });

    // Edit 1: first half a→b. changeRatio vs original = 0.5 ≤ 0.6 → allowed.
    const e1 = 'b'.repeat(25) + 'a'.repeat(25);
    const r1 = await editMessage.handler({ messageId: seq, text: e1 });
    expect(r1.isError).toBeUndefined();

    // Edit 2: second half a→c. vs the CURRENT text (e1) changeRatio = 0.5 → a
    // legitimate correction. But vs the frozen ORIGINAL (50×a) it's 1.0 — the
    // old original-baseline gate would have rejected it. Must be allowed now.
    const e2 = 'b'.repeat(25) + 'c'.repeat(25);
    const r2 = await editMessage.handler({ messageId: seq, text: e2 });
    expect(r2.isError).toBeUndefined();

    const edits = getUndeliveredMessages().filter((m) => JSON.parse(m.content).operation === 'edit');
    expect(edits).toHaveLength(2);
    expect(JSON.parse(edits[edits.length - 1].content).text).toBe(e2);
  });

  it('getCurrentOutboundTextBySeq returns the latest edit text, else the original', () => {
    const seq = writeMessageOut({
      id: 'orig', kind: 'chat', platform_id: 'p', channel_type: 'ios-app-v2',
      thread_id: null, content: JSON.stringify({ text: 'original body long enough to matter here' }),
    });
    // No edits yet → the original text.
    expect(getCurrentOutboundTextBySeq(seq)).toBe('original body long enough to matter here');

    // Mirror what the handler writes: an edit row keyed by the target's platform id.
    // getMessageIdBySeq(seq) with no `delivered` row falls back to the internal id.
    writeMessageOut({
      id: 'e1', kind: 'chat', platform_id: 'p', channel_type: 'ios-app-v2', thread_id: null,
      content: JSON.stringify({ operation: 'edit', messageId: 'orig', text: 'the corrected body text here' }),
    });
    expect(getCurrentOutboundTextBySeq(seq)).toBe('the corrected body text here');

    // A newer edit supersedes the older one.
    writeMessageOut({
      id: 'e2', kind: 'chat', platform_id: 'p', channel_type: 'ios-app-v2', thread_id: null,
      content: JSON.stringify({ operation: 'edit', messageId: 'orig', text: 'the twice-corrected body text' }),
    });
    expect(getCurrentOutboundTextBySeq(seq)).toBe('the twice-corrected body text');
  });

  it('refuses an omit-id "edit my last" when the last message is stale', async () => {
    const seq = writeMessageOut({
      id: 'stale', kind: 'chat', platform_id: 'p', channel_type: 'ios-app-v2',
      thread_id: null, content: JSON.stringify({ text: 'сообщение достаточной длины, отправленное давно' }),
    });
    // Backdate it 2h so the "fix what I just said" convenience no longer applies.
    const old = new Date(Date.now() - 2 * 3600 * 1000).toISOString().replace('T', ' ').slice(0, 19);
    getOutboundDb().prepare('UPDATE messages_out SET timestamp = ? WHERE seq = ?').run(old, seq);

    const res = await editMessage.handler({ text: 'небольшая правка текста' });
    expect(res.isError).toBe(true);
    expect(res.content[0].text).toContain('send_message');
    const edit = getUndeliveredMessages().find((m) => JSON.parse(m.content).operation === 'edit');
    expect(edit).toBeUndefined();
  });
});

describe('edit_message gate telemetry', () => {
  const gateEvents = () =>
    getUndeliveredMessages()
      .map((m) => JSON.parse(m.content))
      .filter((c) => c.action === 'log_gate_event');

  it('logs an allowed edit with its change ratio and lengths', async () => {
    writeMessageOut({
      id: 'm', kind: 'chat', platform_id: 'p', channel_type: 'ios-app-v2',
      thread_id: null, content: JSON.stringify({ text: 'a'.repeat(50) }),
    });
    // 20/50 chars differ → ratio 0.4, allowed.
    await editMessage.handler({ text: 'b'.repeat(20) + 'a'.repeat(30) });
    const ev = gateEvents();
    expect(ev).toHaveLength(1);
    expect(ev[0].decision).toBe('allowed');
    expect(ev[0].ratio).toBeGreaterThan(0);
    expect(ev[0].ratio).toBeLessThan(0.6);
    expect(ev[0].nextLen).toBe(50);
    expect(ev[0].omitId).toBe(true);
  });

  it('logs a refused replacement with the ratio', async () => {
    const seq = writeMessageOut({
      id: 'm', kind: 'chat', platform_id: 'p', channel_type: 'ios-app-v2',
      thread_id: null, content: JSON.stringify({ text: 'a'.repeat(50) }),
    });
    await editMessage.handler({ messageId: seq, text: 'b'.repeat(50) });
    const ev = gateEvents();
    expect(ev.some((e) => e.decision === 'refused_replacement' && e.ratio > 0.6 && e.omitId === false)).toBe(true);
  });

  it('logs a refused stale omit-id edit with its age', async () => {
    const seq = writeMessageOut({
      id: 'm', kind: 'chat', platform_id: 'p', channel_type: 'ios-app-v2',
      thread_id: null, content: JSON.stringify({ text: 'сообщение достаточной длины для гейта здесь' }),
    });
    const old = new Date(Date.now() - 2 * 3600 * 1000).toISOString().replace('T', ' ').slice(0, 19);
    getOutboundDb().prepare('UPDATE messages_out SET timestamp = ? WHERE seq = ?').run(old, seq);
    await editMessage.handler({ text: 'мелкая правка' });
    const ev = gateEvents();
    expect(ev.some((e) => e.decision === 'refused_stale' && e.ageMs > 3600 * 1000 && e.omitId === true)).toBe(true);
  });

  it('truncates stored text to the cap', async () => {
    writeMessageOut({
      id: 'm', kind: 'chat', platform_id: 'p', channel_type: 'ios-app-v2',
      thread_id: null, content: JSON.stringify({ text: 'x'.repeat(50) }),
    });
    // A long edit (this one refuses as a replacement — truncation applies to
    // the stored text either way; we assert the cap, not the decision).
    await editMessage.handler({ text: 'x'.repeat(48) + 'y'.repeat(400) });
    const ev = gateEvents();
    expect(ev[0].nextLen).toBe(448); // real length recorded
    expect(ev[0].next.length).toBe(200); // stored text capped
  });
});
