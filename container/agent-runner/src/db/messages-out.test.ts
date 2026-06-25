// Run: bun test src/db/messages-out.test.ts
import { describe, it, expect, beforeEach } from 'bun:test';
import { getOutboundDb, initTestSessionDb } from './connection.js';
import { writeMessageOut, getUserFacingDispatchCount, resetUserFacingDispatch, getLatestUserFacingOutboundSeq } from './messages-out.js';

function outboundRowCount(): number {
  return (getOutboundDb().prepare('SELECT COUNT(*) AS n FROM messages_out').get() as { n: number }).n;
}

describe('userFacingDispatchCount', () => {
  const base = {
    id: '',
    kind: 'chat',
    platform_id: 'p',
    channel_type: 'c',
    thread_id: null as string | null,
    content: '',
  };

  beforeEach(() => {
    initTestSessionDb();
    resetUserFacingDispatch();
  });

  it('counts a normal chat message', () => {
    writeMessageOut({ ...base, id: 'm1', content: JSON.stringify({ text: 'hi' }) });
    expect(getUserFacingDispatchCount()).toBe(1);
  });

  it('counts a send_photo', () => {
    writeMessageOut({ ...base, id: 'm1', content: JSON.stringify({ operation: 'send_photo', files: ['a.jpg'] }) });
    expect(getUserFacingDispatchCount()).toBe(1);
  });

  it('does NOT count a status ping (progress, not an answer)', () => {
    writeMessageOut({ ...base, id: 'm1', content: JSON.stringify({ type: 'status', text: 'working' }) });
    expect(getUserFacingDispatchCount()).toBe(0);
  });

  it('does NOT count non-chat kinds', () => {
    writeMessageOut({ ...base, id: 'm1', kind: 'system', content: JSON.stringify({ text: 'x' }) });
    expect(getUserFacingDispatchCount()).toBe(0);
  });

  it('accumulates across sends and zeroes on reset (turn boundary)', () => {
    writeMessageOut({ ...base, id: 'm1', content: JSON.stringify({ text: 'a' }) });
    writeMessageOut({ ...base, id: 'm2', content: JSON.stringify({ operation: 'send_photo', files: ['b.jpg'] }) });
    expect(getUserFacingDispatchCount()).toBe(2);
    resetUserFacingDispatch();
    expect(getUserFacingDispatchCount()).toBe(0);
  });
});

describe('recent duplicate suppression', () => {
  const base = {
    id: '',
    kind: 'chat',
    platform_id: 'ios-app-v2:default',
    channel_type: 'ios-app-v2',
    thread_id: null as string | null,
    content: '',
  };

  beforeEach(() => {
    initTestSessionDb();
    resetUserFacingDispatch();
  });

  it('suppresses an identical user-facing message to the same destination written moments earlier', () => {
    // Reproduces the 2026-06-24 jarvis double-send: the agent delivered the
    // same summary via both a <message> block AND the send_message MCP tool.
    // Both funnel through writeMessageOut (across two processes) but share no
    // upstream dedup; the DB-window check in writeMessageOut collapses them.
    const body = JSON.stringify({ text: 'Auth sync 23 июня — коротко: ...' });
    const seq1 = writeMessageOut({ ...base, id: 'm1', content: body });
    const seq2 = writeMessageOut({ ...base, id: 'm2', content: body });
    expect(outboundRowCount()).toBe(1); // only one row actually written
    expect(seq2).toBe(seq1); // the dup reports the original seq, not a new one
    expect(getUserFacingDispatchCount()).toBe(1); // counted once
  });

  it('still delivers identical content to a DIFFERENT destination (broadcast)', () => {
    const body = JSON.stringify({ text: 'same note to two people' });
    writeMessageOut({ ...base, id: 'm1', platform_id: 'A', content: body });
    writeMessageOut({ ...base, id: 'm2', platform_id: 'B', content: body });
    expect(outboundRowCount()).toBe(2);
  });

  it('still delivers identical content to a different thread of the same channel', () => {
    const body = JSON.stringify({ text: 'same answer, two threads' });
    writeMessageOut({ ...base, id: 'm1', thread_id: 't1', content: body });
    writeMessageOut({ ...base, id: 'm2', thread_id: 't2', content: body });
    expect(outboundRowCount()).toBe(2);
  });

  it('does NOT suppress a re-send once the earlier identical row is outside the window', () => {
    // Back-date the first row well beyond the dedup window so the second send
    // is treated as a fresh, intentional message (e.g. a daily recurring line).
    const body = JSON.stringify({ text: 'recurring daily line' });
    writeMessageOut({ ...base, id: 'm1', content: body });
    getOutboundDb()
      .prepare(`UPDATE messages_out SET timestamp = datetime('now', '-1 hour') WHERE id = 'm1'`)
      .run();
    writeMessageOut({ ...base, id: 'm2', content: body });
    expect(outboundRowCount()).toBe(2);
  });

  it('does NOT suppress repeated status pings (progress, not answers)', () => {
    const ping = JSON.stringify({ type: 'status', text: 'working…' });
    writeMessageOut({ ...base, id: 'm1', content: ping });
    writeMessageOut({ ...base, id: 'm2', content: ping });
    expect(outboundRowCount()).toBe(2);
  });

  it('does NOT suppress scheduled (deliver_after) sends with identical content', () => {
    const body = JSON.stringify({ text: 'scheduled reminder' });
    writeMessageOut({ ...base, id: 'm1', deliver_after: '2099-01-01 00:00:00', content: body });
    writeMessageOut({ ...base, id: 'm2', deliver_after: '2099-01-02 00:00:00', content: body });
    expect(outboundRowCount()).toBe(2);
  });
});

describe('getLatestUserFacingOutboundSeq', () => {
  const base = {
    id: '',
    kind: 'chat',
    platform_id: 'p',
    channel_type: 'c',
    thread_id: null as string | null,
    content: '',
  };

  beforeEach(() => {
    initTestSessionDb();
    resetUserFacingDispatch();
  });

  it('returns null when there is no outbound message', () => {
    expect(getLatestUserFacingOutboundSeq()).toBeNull();
  });

  it('returns the seq of the most recent user-facing chat message', () => {
    writeMessageOut({ ...base, id: 'm1', content: JSON.stringify({ text: 'first' }) });
    const seq2 = writeMessageOut({ ...base, id: 'm2', content: JSON.stringify({ text: 'second' }) });
    expect(getLatestUserFacingOutboundSeq()).toBe(seq2);
  });

  it('skips status pings, edits and reactions', () => {
    const real = writeMessageOut({ ...base, id: 'm1', content: JSON.stringify({ text: 'real' }) });
    writeMessageOut({ ...base, id: 'm2', content: JSON.stringify({ type: 'status', text: 'working' }) });
    writeMessageOut({ ...base, id: 'm3', content: JSON.stringify({ operation: 'edit', messageId: 'x', text: 'e' }) });
    writeMessageOut({ ...base, id: 'm4', content: JSON.stringify({ operation: 'reaction', messageId: 'x', emoji: 'heart' }) });
    expect(getLatestUserFacingOutboundSeq()).toBe(real);
  });
});
