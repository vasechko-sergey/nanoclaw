// Run: bun test src/db/messages-out.test.ts
import { describe, it, expect, beforeEach } from 'bun:test';
import { initTestSessionDb } from './connection.js';
import { writeMessageOut, getUserFacingDispatchCount, resetUserFacingDispatch } from './messages-out.js';

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
