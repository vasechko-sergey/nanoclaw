/**
 * One-shot migration from the four-source CLAUDE.md scheme to the
 * single-INSTRUCTIONS.md scheme. Idempotent via a sentinel file in
 * GROUPS_DIR. Per group:
 *   - manual CLAUDE.md → prepend @./INSTRUCTIONS.md + TODO marker
 *   - composed CLAUDE.md (old header) → replace with stub + TODO
 *   - non-empty CLAUDE.local.md → memories/CLAUDE.local-archive.md
 *   - empty CLAUDE.local.md → delete
 *   - memories/ without index.md → seed minimal index
 *   - .claude-shared.md, .claude-fragments/ → deleted
 */
import fs from 'fs';
import path from 'path';

import { GROUPS_DIR } from './config.js';
import { log } from './log.js';

export const SENTINEL_NAME = '.migrated-claude-md-v2';

/**
 * Matches a whole-line `@./.claude-fragments/...` import. The v2 migration
 * deletes the `.claude-fragments/` directory but historically left these
 * `@`-import lines in the body of CLAUDE.md, so every session fed Claude
 * Code 5 dead imports (their content now lives in the shared INSTRUCTIONS.md).
 */
const DEAD_FRAGMENT_IMPORT = /^@\.\/\.claude-fragments\/.*$/gm;

const OLD_COMPOSED_HEADER = '<!-- Composed at spawn — do not edit. Edit CLAUDE.local.md for per-group content. -->';

const TODO_MARKER = '<!-- TODO: review against INSTRUCTIONS.md — drop sections that duplicate the shared preamble. -->';

const STUB_PERSONA = `# TODO: persona

Write the agent's voice, tone, rules, behaviour, and memory layout here.
Sections that duplicate the shared INSTRUCTIONS.md (channels, comms,
behavior defaults) should NOT be repeated here.
`;

interface MigrateOpts {
  groupsDir?: string;
}

export function migrateClaudeMdV2(opts: MigrateOpts = {}): void {
  const groupsDir = opts.groupsDir ?? GROUPS_DIR;
  if (!fs.existsSync(groupsDir)) return;

  const sentinel = path.join(groupsDir, SENTINEL_NAME);
  if (fs.existsSync(sentinel)) return;

  const actions: string[] = [];

  for (const entry of fs.readdirSync(groupsDir, { withFileTypes: true })) {
    if (!entry.isDirectory()) continue;
    if (entry.name.startsWith('.')) continue;

    const dir = path.join(groupsDir, entry.name);
    migrateGroup(dir, entry.name, actions);
  }

  fs.writeFileSync(sentinel, `migrated at ${new Date().toISOString()}\n`);
  log.info('migrate-claude-md-v2 done', { actions });
}

/**
 * Remove dead `@./.claude-fragments/*` import lines from a CLAUDE.md body and
 * collapse the blank-line run they leave behind. Pure string transform.
 */
export function stripDeadFragmentImports(body: string): string {
  if (!DEAD_FRAGMENT_IMPORT.test(body)) return body;
  DEAD_FRAGMENT_IMPORT.lastIndex = 0; // reset the stateful global regex
  return body
    .replace(DEAD_FRAGMENT_IMPORT, '')
    .replace(/\n{3,}/g, '\n\n')
    .replace(/\s+$/, '\n');
}

/**
 * Idempotent cleanup that runs on every startup regardless of the migration
 * sentinel. Installs migrated before the strip-fix shipped still carry the
 * dead fragment imports in their CLAUDE.md; this scrubs them. Only rewrites
 * files that actually contain a dead import.
 */
export function cleanupDeadFragmentImports(opts: MigrateOpts = {}): void {
  const groupsDir = opts.groupsDir ?? GROUPS_DIR;
  if (!fs.existsSync(groupsDir)) return;

  const cleaned: string[] = [];
  for (const entry of fs.readdirSync(groupsDir, { withFileTypes: true })) {
    if (!entry.isDirectory() || entry.name.startsWith('.')) continue;
    const claudeMdPath = path.join(groupsDir, entry.name, 'CLAUDE.md');
    if (!fs.existsSync(claudeMdPath)) continue;
    const original = fs.readFileSync(claudeMdPath, 'utf8');
    const scrubbed = stripDeadFragmentImports(original);
    if (scrubbed !== original) {
      fs.writeFileSync(claudeMdPath, scrubbed);
      cleaned.push(entry.name);
    }
  }
  if (cleaned.length > 0) log.info('cleanup-dead-fragment-imports', { groups: cleaned });
}

function migrateGroup(dir: string, name: string, actions: string[]): void {
  // 1. CLAUDE.md rewrite.
  const claudeMdPath = path.join(dir, 'CLAUDE.md');
  if (fs.existsSync(claudeMdPath)) {
    const original = fs.readFileSync(claudeMdPath, 'utf8');
    let rewritten: string;
    if (original.startsWith(OLD_COMPOSED_HEADER)) {
      rewritten = `@./INSTRUCTIONS.md\n\n${TODO_MARKER}\n\n${STUB_PERSONA}`;
      actions.push(`${name}/CLAUDE.md: replaced composed entry with stub`);
    } else {
      // Strip dead `@./.claude-fragments/*` imports from the body — the
      // directory is deleted below, so leaving the imports would feed Claude
      // Code references to files that no longer exist.
      const cleaned = stripDeadFragmentImports(original);
      rewritten = `@./INSTRUCTIONS.md\n\n${TODO_MARKER}\n\n${cleaned}`;
      actions.push(`${name}/CLAUDE.md: prepended import + TODO`);
    }
    fs.writeFileSync(claudeMdPath, rewritten);
  }

  // 2. CLAUDE.local.md → archive or delete.
  const localPath = path.join(dir, 'CLAUDE.local.md');
  if (fs.existsSync(localPath)) {
    const localContent = fs.readFileSync(localPath, 'utf8');
    if (localContent.trim().length > 0) {
      const memoriesDir = path.join(dir, 'memories');
      fs.mkdirSync(memoriesDir, { recursive: true });
      const archivePath = path.join(memoriesDir, 'CLAUDE.local-archive.md');
      fs.writeFileSync(archivePath, localContent);
      actions.push(`${name}/CLAUDE.local.md → memories/CLAUDE.local-archive.md`);
    }
    fs.unlinkSync(localPath);
  }

  // 3. memories/index.md seed.
  const memoriesDir = path.join(dir, 'memories');
  const indexPath = path.join(memoriesDir, 'index.md');
  if (fs.existsSync(memoriesDir) && !fs.existsSync(indexPath)) {
    const entries = collectMemoryFiles(memoriesDir, memoriesDir);
    const body = '# Memory index\n\n' + entries.map((rel) => `- ${rel}`).join('\n') + '\n';
    fs.writeFileSync(indexPath, body);
    actions.push(`${name}/memories/index.md seeded`);
  }

  // 4. Delete .claude-shared.md and .claude-fragments/.
  const sharedLink = path.join(dir, '.claude-shared.md');
  try {
    fs.unlinkSync(sharedLink);
    actions.push(`${name}/.claude-shared.md removed`);
  } catch {
    /* missing */
  }

  const fragmentsDir = path.join(dir, '.claude-fragments');
  if (fs.existsSync(fragmentsDir)) {
    fs.rmSync(fragmentsDir, { recursive: true, force: true });
    actions.push(`${name}/.claude-fragments/ removed`);
  }
}

function collectMemoryFiles(root: string, dir: string): string[] {
  const out: string[] = [];
  for (const entry of fs.readdirSync(dir, { withFileTypes: true }).sort((a, b) => a.name.localeCompare(b.name))) {
    if (entry.name === 'index.md') continue;
    const full = path.join(dir, entry.name);
    const rel = path.relative(root, full);
    if (entry.isDirectory()) {
      out.push(...collectMemoryFiles(root, full));
    } else if (entry.isFile()) {
      out.push(rel);
    }
  }
  return out;
}
