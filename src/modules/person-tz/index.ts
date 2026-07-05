/**
 * Per-person last-known device timezone.
 *
 * `noteDeviceTz` is called from iOS request handlers that carry an IANA tz
 * (the background pending-pull + proactive triggers). `resolveOwnerTz` is
 * called from scheduling (recurrence + the Сводка-ready detector) to fire on
 * the owner's current wall-clock, falling back to the global TIMEZONE when a
 * person has never reported. Both are best-effort — a failure here must never
 * break request handling or scheduling.
 */
import { getDb } from '../../db/connection.js';
import { isValidTimezone } from '../../timezone.js';
import { log } from '../../log.js';
import { getPersonTz, upsertPersonTz } from './db.js';

/** Record a device-reported tz. Silently ignores junk / non-IANA values. */
export function noteDeviceTz(personKey: string, rawTz: unknown): void {
  try {
    if (typeof personKey !== 'string' || personKey.length === 0) return;
    if (typeof rawTz !== 'string' || !isValidTimezone(rawTz)) return;
    upsertPersonTz(getDb(), personKey, rawTz, new Date().toISOString());
  } catch (err) {
    log.warn('noteDeviceTz failed', { err });
  }
}

/** Owner's current tz for scheduling, or null → caller falls back to global. */
export function resolveOwnerTz(ownerKey: string | null | undefined): string | null {
  if (!ownerKey) return null;
  try {
    const tz = getPersonTz(getDb(), ownerKey);
    return tz && isValidTimezone(tz) ? tz : null;
  } catch {
    return null;
  }
}
