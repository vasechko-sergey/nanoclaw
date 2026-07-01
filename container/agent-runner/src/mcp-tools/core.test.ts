/**
 * Tests for the core MCP tools' interaction with the per-batch routing
 * context. The agent-runner sets a current `inReplyTo` at the top of each
 * batch in poll-loop, and outbound writes from MCP tools (send_message,
 * send_file) must pick it up so a2a return-path routing on the host can
 * correlate replies back to the originating session.
 */
import { describe, it, expect, beforeEach, afterEach } from 'bun:test';

import { initTestSessionDb, closeSessionDb, getInboundDb } from '../db/connection.js';
import { getUndeliveredMessages, writeMessageOut } from '../db/messages-out.js';
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
});
