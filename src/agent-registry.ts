/**
 * Build and publish the shared agent registry.
 *
 * Every agent needs to know who its peers are — canonical name, role, and which
 * a2a kinds they accept. Without that, a relaying agent recalls a peer's name
 * from memory, which is how «Майор Пейн» once became «Паулино».
 *
 * Name comes from `agent_groups.name` — the single source, never duplicated into
 * a descriptor (that duplication is the drift being fixed). Role + a2a contract
 * come from each agent's own `agents/<folder>/agent.json`. The merged result is
 * rendered to `agents.json` (structured) and `agents.md` (what agents read).
 */
import crypto from 'crypto';
import fs from 'fs';
import path from 'path';

import { getAllAgentGroups } from './db/agent-groups.js';
import { log } from './log.js';

function sha(s: string): string {
  return crypto.createHash('sha256').update(s).digest('hex');
}

/** Shape of `agents/<folder>/agent.json`. Every field optional — a partial descriptor degrades to a name-only entry. */
export interface AgentDescriptor {
  role?: string;
  /** kind name → human description of what the agent does with it. */
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
  const d = parsed as Record<string, unknown>;
  // Validate field TYPES, not just the top-level shape. A hand-authored typo
  // (`"aka": "Пейн"` instead of `["Пейн"]`) would otherwise sail through and
  // throw inside the renderer, taking the whole registry down for every agent —
  // exactly what the degrade-gracefully contract above promises cannot happen.
  // An unusable field fails the same way malformed JSON does: name-only entry.
  if (d.role !== undefined && typeof d.role !== 'string') {
    log.warn('agent-registry: agent.json `role` is not a string, ignored', { folder });
    return null;
  }
  if (d.aka !== undefined && (!Array.isArray(d.aka) || d.aka.some((x) => typeof x !== 'string'))) {
    log.warn('agent-registry: agent.json `aka` is not a string array, ignored', { folder });
    return null;
  }
  if (d.a2a_in !== undefined) {
    const a = d.a2a_in;
    if (a === null || typeof a !== 'object' || Array.isArray(a)) {
      log.warn('agent-registry: agent.json `a2a_in` is not an object, ignored', { folder });
      return null;
    }
    if (Object.values(a as Record<string, unknown>).some((v) => typeof v !== 'string')) {
      log.warn('agent-registry: agent.json `a2a_in` has non-string values, ignored', { folder });
      return null;
    }
  }
  return d as AgentDescriptor;
}

/**
 * The kinds this agent accepts over a2a, or `null` when it has made no usable
 * declaration — which DISARMS the gate for it (see `shared/a2a/kinds.ts`).
 *
 * What arms the gate is an explicit `a2a_in`, NOT the presence of the file.
 * Three cases:
 *
 * - **No descriptor, or a malformed one → `null`, disarmed.** These two are
 *   deliberately conflated: both must fail open. A typo in agent.json bouncing
 *   every message an agent receives would be far worse than the drift the gate
 *   prevents. It is also what lets the feature ship inert — no descriptors
 *   exist yet, so every gate is off until one is authored.
 * - **Descriptor with no `a2a_in` → `null`, disarmed.** agent.json predates
 *   this gate and promises that every field is optional (see AgentDescriptor),
 *   so a registry-only entry — a `role`, which is the shipped registry's entire
 *   purpose — must stay inert. Its owner has said nothing about the a2a wire,
 *   and silence is not the claim "I accept nothing but text".
 * - **Explicit `"a2a_in": {}` → `[]`, ARMED, text-only.** This descriptor DOES
 *   make a claim about the wire; the claim is "nothing structured", so every
 *   kind but `text` bounces.
 *
 * `[]` and `null` are therefore NOT interchangeable, in either direction.
 * Normalizing a missing `a2a_in` to `[]` arms every un-migrated agent and
 * bounces all its structured traffic; normalizing `[]` to `null` silently
 * ignores a deliberate declaration.
 */
export function getLegalKinds(agentsDir: string, folder: string): string[] | null {
  const d = readAgentDescriptor(agentsDir, folder);
  if (!d) return null;
  return d.a2a_in === undefined ? null : Object.keys(d.a2a_in);
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

/**
 * Prose destined for a markdown table cell (`name`, `role`). Escape backslashes
 * FIRST — otherwise a value already containing `\|` yields `\\|`, which GFM reads
 * as an escaped backslash followed by a LIVE delimiter, opening a bogus column.
 * `\r` alone is a valid line ending and splits the row, so collapse any CR/LF run.
 * `name` is agent-supplied (create_agent normalizes only `folder`, not `name`) and
 * agent.json is agent-authorable — both are semi-untrusted input to the one
 * document agents read as peer ground truth.
 */
function cell(s: string): string {
  return s
    .replace(/\\/g, '\\\\')
    .replace(/\|/g, '\\|')
    .replace(/[\r\n]+/g, ' ')
    .trim();
}

/**
 * Identifier destined for a `code span` (ids, kind names). Backslash escapes do
 * not apply inside code spans, so escaping can't save us — strip the characters
 * that would break the span or the row instead. Real folders and kind names are
 * `[A-Za-z0-9_-]`, so this is a no-op on every legitimate value.
 */
function ident(s: string): string {
  return s.replace(/[`|\\\r\n]/g, '').trim();
}

/** Prose outside the table (headings, descriptions): only line endings matter. */
function oneLine(s: string): string {
  return s.replace(/[\r\n]+/g, ' ').trim();
}

/** Render the registry as the markdown agents actually read. */
export function renderRegistryMarkdown(entries: RegistryEntry[]): string {
  const lines = [
    '# Реестр агентов',
    '',
    'Кто есть кто в команде. **Генерируется хостом — не редактировать вручную.**',
    'Имя — канон из `agent_groups.name`. `a2a_in` — какие kind агент принимает.',
    '',
    '| id | Имя | Роль | Принимает a2a |',
    '|---|---|---|---|',
  ];
  for (const e of entries) {
    const kinds = Object.keys(e.a2a_in);
    const kindCell = kinds.length > 0 ? kinds.map((k) => `\`${ident(k)}\``).join(', ') : '—';
    lines.push(`| \`${ident(e.id)}\` | ${cell(e.name)} | ${cell(e.role) || '—'} | ${kindCell} |`);
  }
  for (const e of entries) {
    const kinds = Object.entries(e.a2a_in);
    // Gate on anything worth showing — NOT on kinds alone. `aka` is rendered
    // only here, so a receive-only agent's aliases would otherwise never appear.
    if (kinds.length === 0 && !e.role && e.aka.length === 0) continue;
    lines.push('', `## ${oneLine(e.name)} (\`${ident(e.id)}\`)`);
    if (e.role) lines.push(`Роль: ${oneLine(e.role)}`);
    if (e.aka.length > 0) lines.push(`Также зовут: ${e.aka.map(oneLine).join(', ')}`);
    lines.push('');
    for (const [kind, desc] of kinds) {
      lines.push(`- \`${ident(kind)}\` — ${oneLine(desc)}`);
    }
  }
  lines.push('');
  return lines.join('\n');
}

/**
 * Write the registry pair into one person's `global/`. Hash-gated, and
 * write-then-rename so a container reading the read-only mount never sees a
 * half-written file (same idiom as public-profiles.ts). Returns files written.
 */
export function writeRegistryForPerson(personRoot: string, json: string, md: string): number {
  const globalDir = path.join(personRoot, 'global');
  const files: Array<[string, string]> = [
    ['agents.json', json],
    ['agents.md', md],
  ];
  let written = 0;
  for (const [name, body] of files) {
    const dest = path.join(globalDir, name);
    let existing: string | null = null;
    try {
      existing = fs.readFileSync(dest, 'utf8');
    } catch {
      // missing → fall through and write
    }
    if (existing !== null && sha(existing) === sha(body)) continue;
    try {
      fs.mkdirSync(globalDir, { recursive: true });
      const tmpPath = `${dest}.tmp`;
      fs.writeFileSync(tmpPath, body);
      fs.renameSync(tmpPath, dest);
      written++;
    } catch (err) {
      log.warn('agent-registry: failed to write registry file', { dest, err });
    }
  }
  return written;
}

/**
 * Build the registry once and fan it into every person's global dir. Content is
 * person-independent — only the destination varies, so each container resolves
 * the same `/workspace/global/agents.md`. Returns total files written.
 */
export function writeAgentRegistry(userMemoryBase: string, agentsDir: string): number {
  // Abort if the descriptor root itself is unreadable. readAgentDescriptor()
  // returns null for a missing descriptor (normal — not yet authored) and for an
  // unreadable agents/ dir (broken) alike, so without this check a bad agentsDir
  // would republish a fully name-only registry over the good one every sweep,
  // silently. A missing descriptor is expected; a missing agents/ dir is not.
  try {
    fs.readdirSync(agentsDir);
  } catch (err) {
    log.warn('agent-registry: agents dir unreadable, not publishing', { agentsDir, err });
    return 0;
  }

  const entries = buildRegistry(agentsDir);
  // Never publish an empty registry: a transient DB read returning nothing must
  // not blank out a good file that agents are relying on.
  if (entries.length === 0) return 0;

  const json = JSON.stringify(entries, null, 2) + '\n';
  const md = renderRegistryMarkdown(entries);

  let persons: fs.Dirent[];
  try {
    persons = fs.readdirSync(userMemoryBase, { withFileTypes: true });
  } catch {
    return 0; // user-memory doesn't exist yet (pre-migration) — no-op
  }
  let written = 0;
  for (const p of persons) {
    if (!p.isDirectory()) continue;
    written += writeRegistryForPerson(path.join(userMemoryBase, p.name), json, md);
  }
  return written;
}
