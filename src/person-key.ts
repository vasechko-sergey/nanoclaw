import { OWNER_PERSON_KEY } from './config.js';
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
