import { OWNER_PERSON_KEY } from './config.js';
import { getDb, hasTable } from './db/connection.js';
import { getUser } from './modules/permissions/db/users.js';

export { OWNER_PERSON_KEY };

/**
 * Map a channel handle (namespaced user id) to a stable per-human key.
 *
 * - A user row with an explicit person_key → that key.
 * - A known handle with no person_key → the handle itself (each handle is its
 *   own person until mapped — never silently folded into the owner).
 * - `null`/`undefined` userId (system / headless / a2a default) → OWNER_PERSON_KEY.
 */
export function resolvePersonKey(userId: string | null | undefined): string {
  if (userId == null) return OWNER_PERSON_KEY;
  const user = getUser(userId);
  if (user?.person_key) return user.person_key;
  return userId;
}

/**
 * Which person does a channel belong to?
 *
 * An agent group is wired to every person it serves, but a SESSION belongs to
 * exactly one person, and the destinations that session can address must be
 * that person's alone. Without this, an agent answering one owner sees a second
 * human in its destination list and can address them by name — which is how
 * Payne's reply to the owner landed on another household member's phone on
 * 2026-08-15.
 *
 * Resolution order, most specific first:
 *
 * 1. `ios_tokens` — the iOS app is the only channel type two people share, and
 *    the minted device token is the authoritative device↔person map.
 * 2. A `users` row keyed by the bare platform id (`telegram:179311028`).
 * 3. A `users` row under the namespaced form (`cli` + `local` → `cli:local`).
 *    Neither form is universal: `platform_id` already carries the channel
 *    prefix on some channels and not on others.
 * 4. OWNER_PERSON_KEY. A channel nobody claims predates multi-user and is the
 *    owner's. Defaulting to the owner can only ever over-share the owner's own
 *    channels back to the owner; defaulting to anyone else would hand one
 *    person's agent a way to message another person.
 */
export function personKeyForChannel(channelType: string, platformId: string): string {
  const db = getDb();
  if (hasTable(db, 'ios_tokens')) {
    const row = db.prepare('SELECT person_key FROM ios_tokens WHERE platform_id = ?').get(platformId) as
      | { person_key: string }
      | undefined;
    if (row?.person_key) return row.person_key;
  }
  for (const id of [platformId, `${channelType}:${platformId}`]) {
    const user = getUser(id);
    if (user?.person_key) return user.person_key;
  }
  return OWNER_PERSON_KEY;
}
