/**
 * Provision a second (or Nth) iOS person end-to-end, idempotently.
 *
 *   pnpm exec tsx scripts/provision-ios-person.ts <person_key> <name> <муж|жен> \
 *     [--tz "Asia/Makassar (UTC+8, Бали)"] [--lang "русский (английский — fallback)"] \
 *     [--agents jarvis,payne,greg,gordon,scrooge] [--label "Lena iPhone"]
 *
 * Does the steps `mint-ios-token.ts` leaves out: creates her iOS messaging
 * group, adds her as a member of the chosen agent groups, and seeds her
 * per-person global memory (gendered identity.md + about.md + .writer). Mints
 * the bearer token too and prints it ONCE at the end.
 *
 * Agent groups are resolved by FOLDER at runtime — ids differ per install
 * (jarvis is a UUID on the VDS, a slug elsewhere), so never hardcode them.
 *
 * AFTER running this, restart the host: bootstrap-trio then wires her mg to the
 * agents and eager-creates her sessions, stamped with her owner_key via the
 * ios_tokens registry (so no session falls back to the owner's memory). Then
 * give her the printed token to enter in the app (server URL is hardcoded).
 */
import fs from 'fs';
import path from 'path';
import { randomBytes } from 'node:crypto';

import { DATA_DIR } from '../src/config.js';
import { initDb } from '../src/db/connection.js';
import { getAgentGroupByFolder } from '../src/db/agent-groups.js';
import { createMessagingGroup, getMessagingGroupByPlatform } from '../src/db/messaging-groups.js';
import { addMember } from '../src/modules/permissions/db/agent-group-members.js';
import { upsertUser } from '../src/modules/permissions/db/users.js';
import { upsertIosToken } from '../src/channels/ios-app/v2/token-registry.js';
import { userGlobalRoot } from '../src/user-memory.js';

const DEFAULT_AGENTS = ['jarvis', 'payne', 'greg', 'gordon', 'scrooge'];

function flag(name: string, fallback: string): string {
  const i = process.argv.indexOf(`--${name}`);
  return i >= 0 && process.argv[i + 1] ? process.argv[i + 1] : fallback;
}

const [personKey, name, gender] = process.argv.slice(2);
if (!personKey || !name || (gender !== 'муж' && gender !== 'жен')) {
  console.error(
    'usage: provision-ios-person.ts <person_key> <name> <муж|жен> [--tz ...] [--lang ...] [--agents a,b] [--label ...]',
  );
  process.exit(1);
}
const tz = flag('tz', 'Asia/Makassar (UTC+8, Бали)');
const lang = flag('lang', 'русский (английский — fallback)');
const agents = flag('agents', DEFAULT_AGENTS.join(',')).split(',').map((s) => s.trim()).filter(Boolean);
const label = flag('label', `${name} iPhone`);

initDb(path.join(DATA_DIR, 'v2.db'));

// Resolve agent folders → ids up front; fail loudly before mutating anything.
const agentIds = agents.map((folder) => {
  const ag = getAgentGroupByFolder(folder);
  if (!ag) {
    console.error(`ERROR: agent group folder '${folder}' not found — run the host once so bootstrap creates it.`);
    process.exit(1);
  }
  return { folder, id: ag.id };
});

const platformId = `ios-app-v2:${personKey}`;
const now = new Date().toISOString();

// 1) Token (re-mint replaces any prior row for this platform_id).
const rawToken = randomBytes(24).toString('base64url');
upsertIosToken({ rawToken, platformId, personKey, label });

// 2) iOS messaging group (idempotent on platform_id).
const mgId = `mg-ios-${personKey}`;
if (!getMessagingGroupByPlatform('ios-app-v2', platformId)) {
  createMessagingGroup({
    id: mgId,
    channel_type: 'ios-app-v2',
    platform_id: platformId,
    name: label,
    is_group: 0,
    unknown_sender_policy: 'strict',
    created_at: now,
    denied_at: null,
  });
  console.log(`created messaging group ${mgId} (${platformId})`);
} else {
  console.log(`messaging group for ${platformId} already exists — skipped`);
}

// 3) Users row (id = platform_id) carrying her person_key. Required before
//    membership (agent_group_members.user_id FKs users.id) and lets
//    resolvePersonKey map her handle immediately, not only after first connect.
//    iOS auth re-upserts the same row with the token's person_key on connect.
upsertUser({ id: platformId, kind: 'human', display_name: name, person_key: personKey, created_at: now });
console.log(`user ${platformId} -> person_key ${personKey}`);

// 4) Membership on each agent group (INSERT OR IGNORE — idempotent).
for (const { folder, id } of agentIds) {
  // added_by is a FK to users(id); this is a host-script action, not a user → null.
  addMember({ user_id: platformId, agent_group_id: id, added_by: null, added_at: now });
  console.log(`member of ${folder} (${id})`);
}

// 5) Per-person global memory: gendered identity.md (never overwrite an edited
//    one), minimal about.md, and the .writer that lets jarvis own shared facts.
const globalDir = userGlobalRoot(personKey);
fs.mkdirSync(globalDir, { recursive: true });

const identityPath = path.join(globalDir, 'identity.md');
if (!fs.existsSync(identityPath)) {
  fs.writeFileSync(
    identityPath,
    `# Кого ты обслуживаешь

Факты о человеке, которого ты обслуживаешь. Все агенты читают этот файл при
первом сообщении в разговоре. Обращение и грамматический род согласуй по полу.
Меняется только здесь — больше нигде имя/пол не вшиты.

- Имя: ${name}
- Пол: ${gender}
- Часовой пояс по умолчанию: ${tz}
- Язык: ${lang}
`,
  );
  console.log(`seeded ${identityPath}`);
} else {
  console.log(`${identityPath} exists — left as-is`);
}

const aboutPath = path.join(globalDir, 'about.md');
if (!fs.existsSync(aboutPath)) {
  fs.writeFileSync(aboutPath, `# О человеке\n\n(Заполняется агентами по мере общения.)\n`);
  console.log(`seeded ${aboutPath}`);
}

fs.writeFileSync(path.join(globalDir, '.writer'), 'jarvis\n');

console.log('\n--- provisioned ---');
console.log(`person_key:  ${personKey}`);
console.log(`platform_id: ${platformId}`);
console.log(`agents:      ${agents.join(', ')}`);
console.log(`NEXT: restart the host (bootstrap wires + owner-stamps her sessions), then give her the token:`);
console.log(`TOKEN (give to the person, store nowhere else):\n  ${rawToken}`);
