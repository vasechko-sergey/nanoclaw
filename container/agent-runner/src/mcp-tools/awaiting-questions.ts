/**
 * QuestionIds that ask_user_question (interactive.ts) is CURRENTLY polling
 * inbound.db for.
 *
 * A `question_response` row lands in inbound.db as a plain `system` row —
 * indistinguishable, at the DB level, from one nobody is waiting on anymore.
 * poll-loop.ts's isUnclaimedQuestionResponse() reads this set to tell the two
 * apart: a questionId still in here belongs to the tool's own poll loop and
 * must NOT be treated as agent-facing (see the mid-turn drain race explained
 * in interactive.ts, next to where entries are added/removed). Once the tool
 * stops waiting — response found, or its timeout elapses — the id is gone
 * from this set, and a late-arriving row with that id becomes agent-facing.
 *
 * Split into its own module (rather than living in interactive.ts) so
 * poll-loop.ts can import just this Set without pulling in the MCP tool
 * module itself — interactive.ts registers into the MCP `server.ts`
 * registry at import time, and poll-loop.ts must not trigger that as a side
 * effect of checking a predicate.
 */
export const awaitingQuestionIds = new Set<string>();
