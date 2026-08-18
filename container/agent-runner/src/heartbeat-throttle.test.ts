/**
 * The idle watchdog only ever saw an SDK message per completed assistant turn,
 * so a single long generation — Payne writing a 230-line script — looked
 * identical to a dead stream and got aborted at 240s while the agent was still
 * working. The fix turns on partial-message streaming, which raises the event
 * rate from a handful per turn to one per token chunk. `touchHeartbeat()` is an
 * fs.utimesSync on a bind mount, so it must not ride every one of those.
 */
import { describe, it, expect, beforeEach } from 'bun:test';
import { resetHeartbeatThrottle, shouldTouchHeartbeat } from './heartbeat-throttle.js';

describe('shouldTouchHeartbeat', () => {
  beforeEach(() => resetHeartbeatThrottle());

  it('lets the first call through', () => {
    expect(shouldTouchHeartbeat(1_000, 1_000)).toBe(true);
  });

  it('swallows calls inside the window', () => {
    expect(shouldTouchHeartbeat(1_000, 10_000)).toBe(true);
    expect(shouldTouchHeartbeat(1_000, 10_500)).toBe(false);
    expect(shouldTouchHeartbeat(1_000, 10_999)).toBe(false);
  });

  it('lets a call through once the window has passed', () => {
    expect(shouldTouchHeartbeat(1_000, 10_000)).toBe(true);
    expect(shouldTouchHeartbeat(1_000, 11_000)).toBe(true);
  });

  it('a burst of 1000 events in one second costs two touches, not 1000', () => {
    let touched = 0;
    for (let i = 0; i < 1000; i++) if (shouldTouchHeartbeat(1_000, 50_000 + i)) touched++;
    expect(touched).toBe(1);
    expect(shouldTouchHeartbeat(1_000, 51_000)).toBe(true);
  });
});
