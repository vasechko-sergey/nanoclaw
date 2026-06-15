/**
 * Mint an iOS bearer token for a person and register it.
 *   pnpm exec tsx scripts/mint-ios-token.ts <person_key> [label]
 * Prints the raw token ONCE (only its hash is stored). Give it to the person
 * to enter in the app's Settings (server URL + token). The platform_id is
 * derived as `ios-app-v2:<person_key>`. Wiring her to agent groups + adding
 * membership + creating her user-memory tree is a separate step (see the
 * provisioning runbook in the plan).
 */
import path from 'path';
import { randomBytes } from 'node:crypto';
import { DATA_DIR } from '../src/config.js';
import { initDb } from '../src/db/connection.js';
import { upsertIosToken } from '../src/channels/ios-app/v2/token-registry.js';

const [personKey, label] = process.argv.slice(2);
if (!personKey) {
  console.error('usage: mint-ios-token.ts <person_key> [label]');
  process.exit(1);
}
initDb(path.join(DATA_DIR, 'v2.db'));
const rawToken = randomBytes(24).toString('base64url');
const platformId = `ios-app-v2:${personKey}`;
upsertIosToken({ rawToken, platformId, personKey, label: label ?? null });
console.log(`person_key:  ${personKey}`);
console.log(`platform_id: ${platformId}`);
console.log(`TOKEN (give to the person, store nowhere else):\n  ${rawToken}`);
