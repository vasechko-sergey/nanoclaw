/**
 * Tests for ask_user_question's awaitingQuestionIds bookkeeping.
 *
 * The tool blocks polling messages_in for its own response row. While it's
 * polling, poll-loop.ts's mid-turn drain runs concurrently (same agent
 * turn) and must NOT treat that row as agent-facing — see
 * mcp-tools/awaiting-questions.ts and poll-loop.ts's
 * isUnclaimedQuestionResponse(). These tests lock down the add/remove
 * lifecycle of the Set this tool owns: an entry must disappear on every exit
 * path (found, timeout), so a questionId can never wedge as permanently
 * "claimed" and silently swallow a real late answer forever.
 */
import { describe, it, expect, beforeEach, afterEach } from 'bun:test';

import { initTestSessionDb, closeSessionDb, getInboundDb } from '../db/connection.js';
import { getUndeliveredMessages } from '../db/messages-out.js';
import { askUserQuestion, sendCard } from './interactive.js';
import { awaitingQuestionIds } from './awaiting-questions.js';

/** A human channel this agent can address, as the host projects it on every wake. */
function seedChannel(name: string, platformId: string): void {
  getInboundDb()
    .prepare(
      `INSERT INTO destinations (name, display_name, type, channel_type, platform_id, agent_group_id)
       VALUES (?, ?, 'channel', 'ios-app-v2', ?, NULL)`,
    )
    .run(name, name, platformId);
}

/** The session's own conversation, as the host writes it for a chat-bound session. */
function seedSessionRouting(platformId: string, threadId: string | null): void {
  getInboundDb()
    .prepare(
      `INSERT INTO session_routing (id, channel_type, platform_id, thread_id) VALUES (1, 'ios-app-v2', ?, ?)
       ON CONFLICT(id) DO UPDATE SET channel_type = excluded.channel_type,
         platform_id = excluded.platform_id, thread_id = excluded.thread_id`,
    )
    .run(platformId, threadId);
}

beforeEach(() => {
  initTestSessionDb();
  // Every real agent has at least one destination; without one the card tools
  // now refuse rather than write an unaddressed row.
  seedChannel('sergei-iphone', 'ios-app-v2:default');
  // Defensive: awaitingQuestionIds is a module-level singleton (mirrors the
  // real container's single long-lived poll loop), so a leftover entry from
  // a prior test would corrupt this one's `.size` assertions.
  awaitingQuestionIds.clear();
});

afterEach(() => {
  closeSessionDb();
});

/** Pulls the questionId the handler just wrote in its ask_question card. */
function writtenQuestionId(): string {
  const card = getUndeliveredMessages().find((m) => JSON.parse(m.content).type === 'ask_question');
  if (!card) throw new Error('handler did not write an ask_question card');
  return JSON.parse(card.content).questionId as string;
}

function insertResponse(questionId: string, selectedOption: string) {
  getInboundDb()
    .prepare(
      `INSERT INTO messages_in (id, kind, timestamp, status, trigger, on_wake, content)
       VALUES (?, 'system', datetime('now'), 'pending', 1, 0, ?)`,
    )
    .run(
      `qr-${questionId}`,
      JSON.stringify({ type: 'question_response', questionId, selectedOption, userId: 'u1', title: 'T' }),
    );
}

describe('askUserQuestion claims/releases its questionId', () => {
  it('claims the questionId before polling and releases it once the response is found', async () => {
    const promise = askUserQuestion.handler({ title: 'T', question: 'Q?', options: ['ok'], timeout: 5 });

    // Everything up to the tool's first `await sleep(1000)` runs
    // synchronously — by the time control returns here, the card is
    // written and the id is already claimed (no response exists yet, so
    // the first findQuestionResponse check inside the loop missed and the
    // function is now suspended at its first await).
    const questionId = writtenQuestionId();
    expect(awaitingQuestionIds.has(questionId)).toBe(true);

    // Simulate the host writing the late button-click response mid-poll.
    insertResponse(questionId, 'ok');

    const result = await promise;
    expect(result.isError).toBeFalsy();
    expect(result.content[0]).toMatchObject({ type: 'text', text: 'ok' });
    // Released on the "found" exit path — a future response to the same
    // questionId (there won't be one, but in principle) would not be
    // silently swallowed by a stale claim.
    expect(awaitingQuestionIds.has(questionId)).toBe(false);
  });

  it('claims the questionId and releases it when the poll times out unanswered', async () => {
    const promise = askUserQuestion.handler({ title: 'T', question: 'Q?', options: ['ok'], timeout: 0.1 });

    // Claimed synchronously, same as the found-response test above.
    expect(awaitingQuestionIds.size).toBe(1);

    const result = await promise;
    expect(result.isError).toBe(true);
    // Released on the OTHER exit path (timeout, not found) — proves the
    // `finally` covers both branches of the try, not just the happy path.
    expect(awaitingQuestionIds.size).toBe(0);
  });
});

/**
 * Where a card is addressed.
 *
 * Both tools used to read `session_routing` straight, which is empty on every
 * headless/cron session by construction. Greg's scheduled morning and evening
 * check-ins were therefore written with NULL channel_type/platform_id, and the
 * host dropped each one at delivery ("Message missing routing fields") — two
 * days of questions that reached nobody while the tool call itself reported
 * success.
 */
describe('card routing', () => {
  /** The routing fields the handler stamped on its outbound row. */
  function writtenRouting(): { channel_type: string | null; platform_id: string | null; thread_id: string | null } {
    const row = getUndeliveredMessages()[0];
    if (!row) throw new Error('handler wrote no message');
    return { channel_type: row.channel_type, platform_id: row.platform_id, thread_id: row.thread_id };
  }

  it("addresses the session's own conversation, thread included", async () => {
    seedSessionRouting('ios-app-v2:default', 'ios:default');

    await askUserQuestion.handler({ title: 'T', question: 'Q?', options: ['ok'], timeout: 0.1 });

    expect(writtenRouting()).toEqual({
      channel_type: 'ios-app-v2',
      platform_id: 'ios-app-v2:default',
      thread_id: 'ios:default',
    });
  });

  it('falls back to the only human channel when the session has no routing of its own', async () => {
    // The headless case. Peer agents share the list and must not make it
    // ambiguous — no agent can tap a button, so they are not candidates.
    getInboundDb()
      .prepare(
        `INSERT INTO destinations (name, display_name, type, channel_type, platform_id, agent_group_id)
         VALUES ('payne', 'Майор Пейн', 'agent', NULL, NULL, 'payne')`,
      )
      .run();

    await askUserQuestion.handler({ title: 'T', question: 'Q?', options: ['ok'], timeout: 0.1 });

    expect(writtenRouting()).toEqual({
      channel_type: 'ios-app-v2',
      platform_id: 'ios-app-v2:default',
      thread_id: null,
    });
  });

  it('sends to the named destination when one is given', async () => {
    seedSessionRouting('ios-app-v2:default', 'ios:default');
    seedChannel('lena-iphone', 'ios-app-v2:lena');

    await askUserQuestion.handler({ title: 'T', question: 'Q?', options: ['ok'], timeout: 0.1, to: 'lena-iphone' });

    expect(writtenRouting()).toMatchObject({ platform_id: 'ios-app-v2:lena' });
  });

  it('refuses rather than writing an unaddressed card when nothing resolves', async () => {
    getInboundDb().prepare('DELETE FROM destinations').run();

    const result = await askUserQuestion.handler({ title: 'T', question: 'Q?', options: ['ok'], timeout: 0.1 });

    expect(result.isError).toBe(true);
    expect(result.content[0].text).toContain('no human channel');
    // The load-bearing half: nothing undeliverable reached the DB.
    expect(getUndeliveredMessages()).toHaveLength(0);
  });

  it('refuses to guess between two human channels, and names them', async () => {
    seedChannel('lena-iphone', 'ios-app-v2:lena');

    const result = await askUserQuestion.handler({ title: 'T', question: 'Q?', options: ['ok'], timeout: 0.1 });

    expect(result.isError).toBe(true);
    expect(result.content[0].text).toContain('sergei-iphone');
    expect(result.content[0].text).toContain('lena-iphone');
    expect(getUndeliveredMessages()).toHaveLength(0);
  });

  it('refuses to address a card to an agent — nobody there can tap a button', async () => {
    getInboundDb()
      .prepare(
        `INSERT INTO destinations (name, display_name, type, channel_type, platform_id, agent_group_id)
         VALUES ('payne', 'Майор Пейн', 'agent', NULL, NULL, 'payne')`,
      )
      .run();

    const result = await askUserQuestion.handler({
      title: 'T',
      question: 'Q?',
      options: ['ok'],
      timeout: 0.1,
      to: 'payne',
    });

    expect(result.isError).toBe(true);
    expect(getUndeliveredMessages()).toHaveLength(0);
  });

  it('routes send_card through the same chain', async () => {
    const result = await sendCard.handler({ card: { title: 'X' }, fallbackText: 'X' });

    expect(result.isError).toBeFalsy();
    expect(writtenRouting()).toMatchObject({ platform_id: 'ios-app-v2:default' });
  });
});
