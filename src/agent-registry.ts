/**
 * Build and publish the shared agent registry.
 *
 * Every agent needs to know who its peers are — canonical name, role, and which
 * a2a actions they accept. Without that, a relaying agent recalls a peer's name
 * from memory, which is how «Майор Пейн» once became «Паулино».
 *
 * Name comes from `agent_groups.name` — the single source, never duplicated into
 * a descriptor (that duplication is the drift being fixed). Role + a2a contract
 * come from each agent's own `agents/<folder>/agent.json`. The merged result is
 * rendered to `agents.json` (structured) and `agents.md` (what agents read).
 */
import fs from 'fs';
import path from 'path';

import { getAllAgentGroups } from './db/agent-groups.js';
import { log } from './log.js';

/** Shape of `agents/<folder>/agent.json`. Every field optional — a partial descriptor degrades to a name-only entry. */
export interface AgentDescriptor {
  role?: string;
  /** action name → human description of what the agent does with it. */
  a2a_in?: Record<string, string>;
  aka?: string[];
}

export interface RegistryEntry {
  id: string;
  name: string;
  role: string;
  a2a_in: Record<string, string>;
  aka: string[];
}

/**
 * Read `<agentsDir>/<folder>/agent.json`. Returns null when absent (not yet
 * authored) or unusable. A bad descriptor must never take the registry down —
 * the agent still appears, name-only.
 */
export function readAgentDescriptor(agentsDir: string, folder: string): AgentDescriptor | null {
  let raw: string;
  try {
    raw = fs.readFileSync(path.join(agentsDir, folder, 'agent.json'), 'utf8');
  } catch {
    return null; // no descriptor yet
  }
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch (err) {
    log.warn('agent-registry: malformed agent.json, ignored', { folder, err });
    return null;
  }
  if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) {
    log.warn('agent-registry: agent.json is not an object, ignored', { folder });
    return null;
  }
  return parsed as AgentDescriptor;
}

/**
 * Every agent group joined with its descriptor. The DB is the canonical agent
 * list, so an agent with no descriptor still appears (name only) — the registry
 * is a complete who's-who even before descriptors are authored.
 */
export function buildRegistry(agentsDir: string): RegistryEntry[] {
  return getAllAgentGroups().map((g) => {
    const d = readAgentDescriptor(agentsDir, g.folder);
    return {
      id: g.folder,
      name: g.name,
      role: d?.role ?? '',
      a2a_in: d?.a2a_in ?? {},
      aka: d?.aka ?? [],
    };
  });
}

/** Render the registry as the markdown agents actually read. */
export function renderRegistryMarkdown(entries: RegistryEntry[]): string {
  const lines = [
    '# Реестр агентов',
    '',
    'Кто есть кто в команде. **Генерируется хостом — не редактировать вручную.**',
    'Имя — канон из `agent_groups.name`. `a2a_in` — какие action агент принимает.',
    '',
    '| id | Имя | Роль | Принимает a2a |',
    '|---|---|---|---|',
  ];
  for (const e of entries) {
    const actions = Object.keys(e.a2a_in);
    const actionCell = actions.length > 0 ? actions.map((a) => `\`${a}\``).join(', ') : '—';
    lines.push(`| \`${e.id}\` | ${e.name} | ${e.role || '—'} | ${actionCell} |`);
  }
  for (const e of entries) {
    const actions = Object.entries(e.a2a_in);
    if (actions.length === 0) continue;
    lines.push('', `## ${e.name} (\`${e.id}\`)`);
    if (e.role) lines.push(`Роль: ${e.role}`);
    if (e.aka.length > 0) lines.push(`Также зовут: ${e.aka.join(', ')}`);
    lines.push('');
    for (const [action, desc] of actions) {
      lines.push(`- \`${action}\` — ${desc}`);
    }
  }
  lines.push('');
  return lines.join('\n');
}
