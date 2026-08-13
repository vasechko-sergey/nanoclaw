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
import { askUserQuestion } from './interactive.js';
import { awaitingQuestionIds } from './awaiting-questions.js';

beforeEach(() => {
  initTestSessionDb();
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
