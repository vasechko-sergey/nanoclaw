/**
 * Per-batch context the poll loop publishes for downstream consumers
 * (MCP tools, etc.) that don't sit on the poll-loop's call stack.
 *
 * Today the only field is `inReplyTo` — the id of the first inbound
 * message in the batch the agent is currently processing. MCP tools like
 * `send_message` and `send_file` read this and stamp it onto the outbound
 * row so the host's a2a return-path routing can correlate replies back to
 * the originating session.
 *
 * This is module-level state on purpose: the agent-runner is single-process
 * and processes one batch at a time. Poll-loop calls `setCurrentInReplyTo`
 * before invoking the provider and `clearCurrentInReplyTo` after the batch
 * completes (or errors out).
 */
let currentInReplyTo: string | null = null;

export function setCurrentInReplyTo(id: string | null): void {
  currentInReplyTo = id;
}

export function clearCurrentInReplyTo(): void {
  currentInReplyTo = null;
}

export function getCurrentInReplyTo(): string | null {
  return currentInReplyTo;
}

/**
 * The workout the user is in the middle of, when the current turn answers only
 * live workout events (a logged set, a swap) — null otherwise. The workout
 * screen then covers the chat, so text for the user goes to the screen's coach
 * line instead (poll-loop `sendToDestination`). Set per turn: for the initial
 * batch and again for every follow-up pushed into the open query.
 */
let currentLiveWorkout: string | null = null;

export function setCurrentLiveWorkout(workoutId: string | null): void {
  currentLiveWorkout = workoutId;
}

export function getCurrentLiveWorkout(): string | null {
  return currentLiveWorkout;
}
