/**
 * Timezone utilities — mirror of src/timezone.ts (host).
 *
 * The container can't import from src/ (separate tsconfig, different runtime).
 * Kept deliberately byte-aligned with the host module so behaviour is the
 * same on both sides of the session-DB boundary.
 *
 * TIMEZONE is resolved once at module load from process.env.TZ (which the host
 * sets from its own TIMEZONE constant when spawning the container; see
 * src/container-runner.ts). Invalid values fall back to UTC.
 */

/**
 * Check whether a timezone string is a valid IANA identifier
 * that Intl.DateTimeFormat can use.
 */
export function isValidTimezone(tz: string): boolean {
  try {
    Intl.DateTimeFormat(undefined, { timeZone: tz });
    return true;
  } catch {
    return false;
  }
}

/**
 * Return the given timezone if valid IANA, otherwise fall back to UTC.
 */
export function resolveTimezone(tz: string): string {
  return isValidTimezone(tz) ? tz : 'UTC';
}

/**
 * Force a timestamp string to be read as UTC when it carries no zone of its own.
 *
 * `messages_in.timestamp` is not written in one format: the router stores
 * `new Date().toISOString()` (ends in `Z`), while the scheduling path stores
 * SQLite `datetime('now')` — UTC, but rendered `YYYY-MM-DD HH:MM:SS` with no
 * `Z`. `new Date()` reads that second form as CONTAINER-local time, so an
 * agent running with TZ=Asia/Makassar saw its 11:16 daily-cycle message
 * stamped 3:16 AM. Eight hours is enough to slide the agent's sense of
 * "today" onto the wrong date.
 *
 * Strings that already declare a zone (`Z` or `±HH:MM`) pass through untouched.
 */
function normalizeUtcIso(input: string): string {
  const s = input.trim();
  if (/Z$|[+-]\d{2}:?\d{2}$/.test(s)) return s;
  return s.replace(' ', 'T') + 'Z';
}

/**
 * Convert a UTC ISO timestamp to a localized display string.
 * Uses the Intl API (no external dependencies).
 * Falls back to UTC if the timezone is invalid.
 */
export function formatLocalTime(utcIso: string, timezone: string): string {
  const date = new Date(normalizeUtcIso(utcIso));
  return date.toLocaleString('en-US', {
    timeZone: resolveTimezone(timezone),
    // Weekday included on purpose: the agent reasons about "is it Monday yet"
    // far more reliably when told than when made to derive it from the date.
    weekday: 'short',
    year: 'numeric',
    month: 'short',
    day: 'numeric',
    hour: 'numeric',
    minute: '2-digit',
    hour12: true,
  });
}

function resolveContainerTimezone(): string {
  const candidates = [process.env.TZ, Intl.DateTimeFormat().resolvedOptions().timeZone];
  for (const tz of candidates) {
    if (tz && isValidTimezone(tz)) return tz;
  }
  return 'UTC';
}

export const TIMEZONE = resolveContainerTimezone();

/**
 * The zone the OWNER is currently living in — not the container's.
 *
 * `TZ` (and therefore `TIMEZONE`) is the global host zone; the owner's device
 * zone is passed separately as `OWNER_TZ` at spawn time, resolved per session
 * owner via person-tz (see src/container-runner.ts). Anything that interprets
 * or renders the user's wall clock — "9pm" in a scheduled task — must use this,
 * because the host's recurrence sweep evaluates cron in the same owner zone
 * (src/modules/scheduling/recurrence.ts). Using TIMEZONE there makes the first
 * run and every repeat disagree.
 *
 * Read at call time rather than frozen at module load so tests can vary it;
 * in production the host sets it once per container.
 */
export function ownerTimezone(): string {
  const tz = process.env.OWNER_TZ;
  return tz && isValidTimezone(tz) ? tz : TIMEZONE;
}

/**
 * Interpret a naive ISO-like timestamp (no trailing `Z`, no offset) as wall-clock
 * time in `tz` and return the corresponding UTC Date. Strings that already carry
 * offset info (`Z` or `±HH:MM`) are passed through to the Date constructor
 * unchanged.
 *
 * Algorithm: treat the naive string as UTC, ask Intl.DateTimeFormat what that
 * UTC instant is called in `tz`, then invert the offset. Near DST boundaries
 * this can be off by an hour for ~1h of wall-clock time per year; acceptable
 * for scheduling where the agent normally picks round-hour targets.
 */
export function parseZonedToUtc(input: string, tz: string): Date {
  const hasOffset = /Z$|[+-]\d{2}:?\d{2}$/.test(input.trim());
  if (hasOffset) return new Date(input);

  const zone = resolveTimezone(tz);
  const asIfUtc = new Date(input + 'Z');
  if (Number.isNaN(asIfUtc.getTime())) return asIfUtc;

  const fmt = new Intl.DateTimeFormat('en-US', {
    timeZone: zone,
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
    second: '2-digit',
    hour12: false,
  });
  const parts = Object.fromEntries(
    fmt
      .formatToParts(asIfUtc)
      .filter((p) => p.type !== 'literal')
      .map((p) => [p.type, p.value]),
  );
  const hour = parts.hour === '24' ? '00' : parts.hour;
  const zonedAsUtcMs = Date.UTC(
    Number(parts.year),
    Number(parts.month) - 1,
    Number(parts.day),
    Number(hour),
    Number(parts.minute),
    Number(parts.second),
  );
  const offsetMs = zonedAsUtcMs - asIfUtc.getTime();
  return new Date(asIfUtc.getTime() - offsetMs);
}
