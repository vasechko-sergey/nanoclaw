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
}
