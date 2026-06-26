import fs from 'fs';
import path from 'path';

import { DATA_DIR } from './config.js';

/** The four writable memory subdirs that move out of groups/<folder>/ per person. */
export const MEMORY_SUBDIRS = ['memories', 'conversations', 'health', 'scratch'] as const;

/** data/user-memory/<personKey>/<agentFolder> — private memory root for one (person, agent). */
export function userMemoryRoot(personKey: string, agentFolder: string): string {
  return path.join(DATA_DIR, 'user-memory', personKey, agentFolder);
}

/** data/user-memory/<personKey>/global — per-person shared-facts + cross-agent profiles. */
export function userGlobalRoot(personKey: string): string {
  return path.join(DATA_DIR, 'user-memory', personKey, 'global');
}

/** data/user-memory/<personKey>/shared — per-person shared wiki, RW for all agents. */
export function userSharedRoot(personKey: string): string {
  return path.join(DATA_DIR, 'user-memory', personKey, 'shared');
}

const DEFAULT_CLAUDE_SETTINGS =
  JSON.stringify(
    {
      env: {
        CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS: '1',
        CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD: '1',
        CLAUDE_CODE_DISABLE_AUTO_MEMORY: '0',
      },
      hooks: {
        PreCompact: [{ hooks: [{ type: 'command', command: 'bun /app/src/compact-instructions.ts' }] }],
      },
    },
    null,
    2,
  ) + '\n';

const SHARED_WIKI_BLOCKS = ['nutrition', 'training', 'health', 'finance', 'general'] as const;

const SHARED_WIKI_README = `# Общая вики-память

Курированные выводы агентов. Каждый пишет только в свой блок; читают все.
Механизм — INSTRUCTIONS §Wiki memory.

- \`nutrition/\` — питание (Gordon)
- \`training/\` — тренировки (Payne)
- \`health/\` — здоровье (Greg)
- \`finance/\` — финансы (Scrooge)
- \`general/\` — общий контекст о владельце (Jarvis)

\`log.md\` — хронология публикаций (append-only).
`;

const SHARED_WIKI_LOG = `# Журнал публикаций общей вики

<!-- 1 строка на публикацию: ## [YYYY-MM-DD] <agent> <domain> | <что> -->
`;

/**
 * Idempotently scaffold the per-person shared wiki at
 * data/user-memory/<person>/shared/: the five domain block dirs, a static
 * README, and an append-only log.md. README/log are written only when absent —
 * the log accumulates publish history and must never be clobbered.
 */
function scaffoldSharedWiki(personKey: string): void {
  const sharedDir = userSharedRoot(personKey);
  for (const block of SHARED_WIKI_BLOCKS) {
    fs.mkdirSync(path.join(sharedDir, block), { recursive: true });
  }
  const readme = path.join(sharedDir, 'README.md');
  if (!fs.existsSync(readme)) fs.writeFileSync(readme, SHARED_WIKI_README);
  const log = path.join(sharedDir, 'log.md');
  if (!fs.existsSync(log)) fs.writeFileSync(log, SHARED_WIKI_LOG);
}

/**
 * Idempotently scaffold the per-person memory tree for one (person, agent):
 * memory subdirs, a private .claude (settings.json + skills/), and the
 * per-person global dir (profiles/). Safe to call on every container spawn.
 */
export function initUserMemory(personKey: string, agentFolder: string): void {
  const root = userMemoryRoot(personKey, agentFolder);
  for (const sub of MEMORY_SUBDIRS) {
    fs.mkdirSync(path.join(root, sub), { recursive: true });
  }
  const claudeDir = path.join(root, '.claude');
  fs.mkdirSync(path.join(claudeDir, 'skills'), { recursive: true });
  const settingsFile = path.join(claudeDir, 'settings.json');
  if (!fs.existsSync(settingsFile)) fs.writeFileSync(settingsFile, DEFAULT_CLAUDE_SETTINGS);

  const globalDir = userGlobalRoot(personKey);
  fs.mkdirSync(path.join(globalDir, 'profiles'), { recursive: true });

  scaffoldSharedWiki(personKey);
}
