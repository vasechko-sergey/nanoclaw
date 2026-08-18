/**
 * Rate limiter for the container heartbeat touch.
 *
 * The poll loop touches `/workspace/.heartbeat` on every provider event so the
 * host's stale-session sweep can tell a working container from a wedged one.
 * That was cheap while the SDK emitted a handful of events per turn. With
 * partial-message streaming on (see providers/claude.ts — it is what keeps the
 * idle watchdog from killing a long single generation) events arrive per token
 * chunk, and the touch is an `fs.utimesSync` against a bind mount.
 *
 * The host's staleness threshold is minutes, so one touch per second carries
 * exactly as much information as one per token and costs three orders of
 * magnitude less.
 */
let lastTouchMs = 0;

/** Whether enough time has passed to be worth another touch. Advances the clock when it says yes. */
export function shouldTouchHeartbeat(minIntervalMs: number, nowMs: number): boolean {
  if (lastTouchMs !== 0 && nowMs - lastTouchMs < minIntervalMs) return false;
  lastTouchMs = nowMs;
  return true;
}

/** Test seam — forget the last touch so each case starts from a clean slate. */
export function resetHeartbeatThrottle(): void {
  lastTouchMs = 0;
}
