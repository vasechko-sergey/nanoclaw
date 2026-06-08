/**
 * Wire an additional agent_group to an existing messaging group.
 *
 * Use when adding a second/third agent to a device that already talks to
 * one agent — multi-agent fan-out (e.g. for the ios-app channel) uses a
 * single messaging_group_id per device with multiple
 * messaging_group_agents rows. `messaging_groups` enforces
 * UNIQUE(channel_type, platform_id), so a new messaging group per agent
 * is never the right shape; the router already fans one mg out to N agents
 * via `findSessionForAgent`.
 *
 * Usage:
 *   pnpm exec tsx scripts/wire-extra-agent.ts \
 *     --channel ios-app-v2 \
 *     --platform-id "ios-app:0123-...-DEAD" \
 *     --agent-group greg
 *
 * Idempotent — re-running with the same args is a no-op.
 */
import path from 'path';

import { DATA_DIR } from '../src/config.js';
import { getAgentGroup } from '../src/db/agent-groups.js';
import { initDb } from '../src/db/connection.js';
import {
  createMessagingGroupAgent,
  getMessagingGroupAgentByPair,
  getMessagingGroupByPlatform,
} from '../src/db/messaging-groups.js';
import { runMigrations } from '../src/db/migrations/index.js';

interface Args {
  channel: string;
  platformId: string;
  agentGroupId: string;
}

function parseArgs(argv: string[]): Args {
  const out: Partial<Args> = {};
  for (let i = 0; i < argv.length; i++) {
    const k = argv[i];
    const v = argv[i + 1];
    switch (k) {
      case '--channel':
        out.channel = v;
        i++;
        break;
      case '--platform-id':
        out.platformId = v;
        i++;
        break;
      case '--agent-group':
        out.agentGroupId = v;
        i++;
        break;
    }
  }
  const required: (keyof Args)[] = ['channel', 'platformId', 'agentGroupId'];
  const missing = required.filter((k) => !out[k]);
  if (missing.length) {
    console.error(
      `Missing required args: ${missing
        .map((k) => `--${k.replace(/([A-Z])/g, '-$1').toLowerCase()}`)
        .join(', ')}`,
    );
    console.error(
      'Usage: pnpm exec tsx scripts/wire-extra-agent.ts --channel <c> --platform-id <p> --agent-group <ag-id>',
    );
    process.exit(2);
  }
  return {
    channel: out.channel!,
    platformId: out.platformId!,
    agentGroupId: out.agentGroupId!,
  };
}

function generateId(prefix: string): string {
  return `${prefix}-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
}

function main(): void {
  const args = parseArgs(process.argv.slice(2));

  const db = initDb(path.join(DATA_DIR, 'v2.db'));
  runMigrations(db); // idempotent

  const ag = getAgentGroup(args.agentGroupId);
  if (!ag) {
    console.error(`agent_group not found: ${args.agentGroupId}`);
    process.exit(3);
  }

  const mg = getMessagingGroupByPlatform(args.channel, args.platformId);
  if (!mg) {
    console.error(
      `messaging_group not found for channel=${args.channel} platform_id=${args.platformId}`,
    );
    console.error('Run init-first-agent for the primary agent on this device first.');
    process.exit(3);
  }

  const existing = getMessagingGroupAgentByPair(mg.id, ag.id);
  if (existing) {
    console.log(`Wiring already exists: ${existing.id} (mg=${mg.id} ag=${ag.id})`);
    return;
  }

  const now = new Date().toISOString();
  createMessagingGroupAgent({
    id: generateId('mga'),
    messaging_group_id: mg.id,
    agent_group_id: ag.id,
    // Mirror init-first-agent's wireIfMissing defaults: DMs (is_group=0)
    // get a '.' pattern (respond to everything); group chats default to
    // mention-only so a second agent doesn't double-reply to every line.
    engage_mode: mg.is_group === 0 ? 'pattern' : 'mention',
    engage_pattern: mg.is_group === 0 ? '.' : null,
    sender_scope: 'all',
    ignored_message_policy: 'drop',
    session_mode: 'shared',
    priority: 0,
    created_at: now,
  });

  console.log(
    `Wired mg=${mg.id} (${mg.channel_type} ${mg.platform_id}) -> ag=${ag.id}`,
  );
}

main();
