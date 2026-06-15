/**
 * Assign a person_key to one or more user handles.
 *   pnpm exec tsx scripts/set-person-key.ts sergei telegram:123 ios-app-v2:default
 */
import path from 'path';
import { DATA_DIR } from '../src/config.js';
import { initDb } from '../src/db/connection.js';
import { setPersonKey, getUser } from '../src/modules/permissions/db/users.js';

const [personKey, ...handles] = process.argv.slice(2);
if (!personKey || handles.length === 0) {
  console.error('usage: set-person-key.ts <person_key> <handle> [handle...]');
  process.exit(1);
}
initDb(path.join(DATA_DIR, 'v2.db'));
for (const h of handles) {
  if (!getUser(h)) {
    console.warn(`WARN: user ${h} not found — skipping (it must have messaged at least once)`);
    continue;
  }
  setPersonKey(h, personKey);
  console.log(`set ${h} -> ${personKey}`);
}
