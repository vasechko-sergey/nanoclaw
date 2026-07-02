import fs from 'fs';
import path from 'path';

import { AGENTS_DIR, DATA_DIR, GROUPS_DIR } from './config.js';
import { ensureContainerConfig } from './db/container-configs.js';
import { log } from './log.js';
import type { AgentGroup } from './types.js';

const DEFAULT_SETTINGS_JSON =
  JSON.stringify(
    {
      env: {
        CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS: '1',
        CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD: '1',
        CLAUDE_CODE_DISABLE_AUTO_MEMORY: '0',
      },
      hooks: {
        PreCompact: [
          {
            hooks: [
              {
                type: 'command',
                command: 'bun /app/src/compact-instructions.ts',
              },
            ],
          },
        ],
      },
    },
    null,
    2,
  ) + '\n';

/**
 * Initialize the on-disk filesystem state for an agent group. Idempotent —
 * every step is gated on the target not already existing, so re-running on
 * an already-initialized group is a no-op.
 *
 * Called once per group lifetime at creation, or defensively from
 * `buildMounts()` for groups that pre-date this code path.
 *
 * Source code and skills are shared RO mounts — not copied per-group.
 * Skill symlinks are synced at spawn time by container-runner.ts.
 *
 * `CLAUDE.md` is NOT written here — it's a static, hand-maintained file on
 * disk (the host never generates or composes it). The shared `INSTRUCTIONS.md`
 * is likewise static and mounted read-only by `buildMounts()`. Nothing seeds
 * `CLAUDE.local.md`; per-group memory lives in `memories/` and CLAUDE.md.
 */
export function initGroupFilesystem(group: AgentGroup, opts?: { instructions?: string | null }): void {
  const initialized: string[] = [];

  // 1. groups/<folder>/ — holds the materialized container.json (and, for
  // not-yet-migrated groups, legacy code that buildMounts' cpSync fallback copies).
  const groupDir = path.resolve(GROUPS_DIR, group.folder);
  if (!fs.existsSync(groupDir)) {
    fs.mkdirSync(groupDir, { recursive: true });
    initialized.push('groupDir');
  }

  // 1b. When called from a CREATION flow (opts passed), seed the shared CODE root
  // agents/<folder>/ so the new agent is born into the shared-code mount model.
  // The defensive call from buildMounts() passes no opts and skips this, leaving a
  // pre-existing legacy group on the cpSync fallback (never emptying its code).
  if (opts) {
    scaffoldAgentCode(group, opts.instructions);
    initialized.push('agents/<folder> (shared code)');
  }

  // Ensure container_configs row exists in the DB. Idempotent — no-op if
  // the row already exists (e.g. created by backfill or group creation).
  ensureContainerConfig(group.id);
  initialized.push('container_configs');

  // 2. data/v2-sessions/<id>/.claude-shared/ — Claude state + per-group skills
  const claudeDir = path.join(DATA_DIR, 'v2-sessions', group.id, '.claude-shared');
  if (!fs.existsSync(claudeDir)) {
    fs.mkdirSync(claudeDir, { recursive: true });
    initialized.push('.claude-shared');
  }

  const settingsFile = path.join(claudeDir, 'settings.json');
  if (!fs.existsSync(settingsFile)) {
    fs.writeFileSync(settingsFile, DEFAULT_SETTINGS_JSON);
    initialized.push('settings.json');
  } else {
    ensurePreCompactHook(settingsFile, initialized);
  }

  // Skills directory — created empty here; symlinks are synced at spawn
  // time by container-runner.ts based on container.json skills selection.
  const skillsDst = path.join(claudeDir, 'skills');
  if (!fs.existsSync(skillsDst)) {
    fs.mkdirSync(skillsDst, { recursive: true });
    initialized.push('skills/');
  }

  if (initialized.length > 0) {
    log.info('Initialized group filesystem', {
      group: group.name,
      folder: group.folder,
      id: group.id,
      steps: initialized,
    });
  }
}

/**
 * Seed a new agent's shared CODE root: agents/<folder>/{CLAUDE.md, skills/, scripts/}.
 * These are bind-mounted into every session container by buildMounts (shared-code
 * model), so the agent's skill/script edits persist and are shared across its users.
 *
 * Idempotent: the code dirs are ensured (mkdir -p), and CLAUDE.md is written ONLY if
 * absent — an agent's own edits to its persona (or Phase 1-3 migrated content) are
 * never clobbered. CLAUDE.md imports the shared `@./INSTRUCTIONS.md`, then the
 * caller-supplied persona (or a bare `# <name>` heading when none is given).
 */
export function scaffoldAgentCode(group: Pick<AgentGroup, 'folder' | 'name'>, instructions?: string | null): void {
  const agentRoot = path.resolve(AGENTS_DIR, group.folder);
  fs.mkdirSync(path.join(agentRoot, 'skills'), { recursive: true });
  fs.mkdirSync(path.join(agentRoot, 'scripts'), { recursive: true });
  const claudeMd = path.join(agentRoot, 'CLAUDE.md');
  if (!fs.existsSync(claudeMd)) {
    const persona = instructions?.trim() ? `${instructions.trim()}\n` : `# ${group.name}\n`;
    fs.writeFileSync(claudeMd, `@./INSTRUCTIONS.md\n\n${persona}`);
  }
}

const PRE_COMPACT_COMMAND = 'bun /app/src/compact-instructions.ts';

/**
 * Patch an existing settings.json to add the PreCompact hook if missing.
 * Runs on every group init so pre-existing groups pick up the hook.
 */
function ensurePreCompactHook(settingsFile: string, initialized: string[]): void {
  try {
    const raw = fs.readFileSync(settingsFile, 'utf-8');
    const settings = JSON.parse(raw);

    // Check if there's already a PreCompact hook with our command.
    const existing = settings.hooks?.PreCompact as unknown[] | undefined;
    if (existing && JSON.stringify(existing).includes(PRE_COMPACT_COMMAND)) return;

    // Add the hook, preserving existing hooks.
    if (!settings.hooks) settings.hooks = {};
    if (!settings.hooks.PreCompact) settings.hooks.PreCompact = [];
    settings.hooks.PreCompact.push({
      hooks: [{ type: 'command', command: PRE_COMPACT_COMMAND }],
    });

    fs.writeFileSync(settingsFile, JSON.stringify(settings, null, 2) + '\n');
    initialized.push('settings.json (added PreCompact hook)');
  } catch {
    // Don't break init if settings.json is malformed — it'll use whatever's there.
  }
}
