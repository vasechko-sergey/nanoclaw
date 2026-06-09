import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import path from 'path';
import os from 'os';
import fs from 'fs';

import {
  migrateClaudeMdV2,
  cleanupDeadFragmentImports,
  stripDeadFragmentImports,
  SENTINEL_NAME,
} from './migrate-claude-md-v2.js';

let tmp: string;
let groupsDir: string;

beforeEach(() => {
  tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'mig-claude-'));
  groupsDir = path.join(tmp, 'groups');
  fs.mkdirSync(groupsDir, { recursive: true });
});

afterEach(() => {
  fs.rmSync(tmp, { recursive: true, force: true });
});

function makeGroup(name: string, files: Record<string, string>): string {
  const dir = path.join(groupsDir, name);
  fs.mkdirSync(dir, { recursive: true });
  for (const [rel, content] of Object.entries(files)) {
    const filePath = path.join(dir, rel);
    fs.mkdirSync(path.dirname(filePath), { recursive: true });
    fs.writeFileSync(filePath, content);
  }
  return dir;
}

describe('migrateClaudeMdV2', () => {
  it('prepends the @./INSTRUCTIONS.md import to a manual CLAUDE.md', () => {
    makeGroup('payne', { 'CLAUDE.md': '# Майор Пейн\n\nперсона...' });
    migrateClaudeMdV2({ groupsDir });
    const out = fs.readFileSync(path.join(groupsDir, 'payne', 'CLAUDE.md'), 'utf8');
    expect(out.startsWith('@./INSTRUCTIONS.md')).toBe(true);
    expect(out).toContain('# Майор Пейн');
    expect(out).toContain('TODO: review against INSTRUCTIONS.md');
  });

  it('replaces a composed CLAUDE.md (had the old composed header) with a stub', () => {
    const composed =
      '<!-- Composed at spawn — do not edit. Edit CLAUDE.local.md for per-group content. -->\n' +
      '@./.claude-shared.md\n' +
      '@./.claude-fragments/skill-welcome.md\n';
    makeGroup('blank', { 'CLAUDE.md': composed });
    migrateClaudeMdV2({ groupsDir });
    const out = fs.readFileSync(path.join(groupsDir, 'blank', 'CLAUDE.md'), 'utf8');
    expect(out.startsWith('@./INSTRUCTIONS.md')).toBe(true);
    expect(out).not.toContain('Composed at spawn');
    expect(out).not.toContain('@./.claude-shared.md');
    expect(out).toContain('TODO: persona');
  });

  it('archives a non-empty CLAUDE.local.md into memories/CLAUDE.local-archive.md', () => {
    makeGroup('jarvis', {
      'CLAUDE.md': '# Jarvis\n\nперсона',
      'CLAUDE.local.md': 'старая память',
    });
    migrateClaudeMdV2({ groupsDir });
    const archive = path.join(groupsDir, 'jarvis', 'memories', 'CLAUDE.local-archive.md');
    expect(fs.existsSync(archive)).toBe(true);
    expect(fs.readFileSync(archive, 'utf8')).toBe('старая память');
    expect(fs.existsSync(path.join(groupsDir, 'jarvis', 'CLAUDE.local.md'))).toBe(false);
  });

  it('leaves an empty CLAUDE.local.md alone and deletes it', () => {
    makeGroup('payne2', { 'CLAUDE.md': '# Payne\n\n.', 'CLAUDE.local.md': '' });
    migrateClaudeMdV2({ groupsDir });
    expect(fs.existsSync(path.join(groupsDir, 'payne2', 'CLAUDE.local.md'))).toBe(false);
    expect(fs.existsSync(path.join(groupsDir, 'payne2', 'memories', 'CLAUDE.local-archive.md'))).toBe(false);
  });

  it('seeds memories/index.md when memories/ exists but the index does not', () => {
    makeGroup('jarvis2', {
      'CLAUDE.md': '# J\n\n.',
      'memories/profile.md': 'p',
      'memories/people/ivan.md': 'i',
    });
    migrateClaudeMdV2({ groupsDir });
    const index = fs.readFileSync(path.join(groupsDir, 'jarvis2', 'memories', 'index.md'), 'utf8');
    expect(index).toContain('# Memory index');
    expect(index).toContain('profile.md');
    expect(index).toContain('people/ivan.md');
  });

  it('removes .claude-shared.md symlink and .claude-fragments/ directory', () => {
    const dir = makeGroup('blank2', { 'CLAUDE.md': '# B\n\n.' });
    fs.symlinkSync('/app/CLAUDE.md', path.join(dir, '.claude-shared.md'));
    fs.mkdirSync(path.join(dir, '.claude-fragments'));
    fs.writeFileSync(path.join(dir, '.claude-fragments', 'skill-welcome.md'), 'x');
    migrateClaudeMdV2({ groupsDir });
    expect(fs.existsSync(path.join(dir, '.claude-shared.md'))).toBe(false);
    expect(fs.existsSync(path.join(dir, '.claude-fragments'))).toBe(false);
  });

  it('strips dead @./.claude-fragments/* imports from a manual CLAUDE.md body', () => {
    const body =
      '# Persona\n\nrules here\n\n' +
      '@./.claude-fragments/module-core.md\n' +
      '@./.claude-fragments/module-scheduling.md\n' +
      '@./.claude-fragments/skill-onecli-gateway.md\n';
    makeGroup('jarvis', { 'CLAUDE.md': body });
    migrateClaudeMdV2({ groupsDir });
    const out = fs.readFileSync(path.join(groupsDir, 'jarvis', 'CLAUDE.md'), 'utf8');
    expect(out).not.toContain('.claude-fragments');
    expect(out).toContain('# Persona');
    expect(out).toContain('rules here');
    expect(out.startsWith('@./INSTRUCTIONS.md')).toBe(true);
  });

  it('writes the sentinel after a successful run', () => {
    makeGroup('x', { 'CLAUDE.md': '# X\n\n.' });
    migrateClaudeMdV2({ groupsDir });
    expect(fs.existsSync(path.join(groupsDir, SENTINEL_NAME))).toBe(true);
  });

  it('is a no-op on a second run because the sentinel exists', () => {
    makeGroup('y', { 'CLAUDE.md': '# Y\n\n.' });
    migrateClaudeMdV2({ groupsDir });
    const first = fs.readFileSync(path.join(groupsDir, 'y', 'CLAUDE.md'), 'utf8');
    migrateClaudeMdV2({ groupsDir });
    const second = fs.readFileSync(path.join(groupsDir, 'y', 'CLAUDE.md'), 'utf8');
    expect(second).toBe(first);
    const occurrences = (second.match(/TODO: review against INSTRUCTIONS.md/g) || []).length;
    expect(occurrences).toBe(1);
  });
});

describe('stripDeadFragmentImports', () => {
  it('removes dead fragment imports and collapses blank runs', () => {
    const input = 'a\n\n@./.claude-fragments/module-core.md\n@./.claude-fragments/module-cli.md\n\nb\n';
    const out = stripDeadFragmentImports(input);
    expect(out).not.toContain('.claude-fragments');
    expect(out).toContain('a');
    expect(out).toContain('b');
    expect(out).not.toMatch(/\n{3,}/);
  });

  it('is a no-op when there are no dead imports', () => {
    const input = '# Persona\n\nclean body\n';
    expect(stripDeadFragmentImports(input)).toBe(input);
  });

  it('is idempotent', () => {
    const input = 'x\n@./.claude-fragments/a.md\ny\n';
    const once = stripDeadFragmentImports(input);
    expect(stripDeadFragmentImports(once)).toBe(once);
  });
});

describe('cleanupDeadFragmentImports', () => {
  it('scrubs already-migrated CLAUDE.md files regardless of the sentinel', () => {
    // Simulate an install migrated before the strip-fix: sentinel present,
    // CLAUDE.md already has the @./INSTRUCTIONS.md import + dead refs.
    fs.writeFileSync(path.join(groupsDir, SENTINEL_NAME), 'migrated\n');
    makeGroup('jarvis', {
      'CLAUDE.md': '@./INSTRUCTIONS.md\n\n# Persona\n\n@./.claude-fragments/module-core.md\n',
    });
    cleanupDeadFragmentImports({ groupsDir });
    const out = fs.readFileSync(path.join(groupsDir, 'jarvis', 'CLAUDE.md'), 'utf8');
    expect(out).not.toContain('.claude-fragments');
    expect(out).toContain('# Persona');
    expect(out.startsWith('@./INSTRUCTIONS.md')).toBe(true);
  });

  it('leaves a clean CLAUDE.md byte-identical', () => {
    const clean = '@./INSTRUCTIONS.md\n\n# Persona\n\nbody\n';
    makeGroup('payne', { 'CLAUDE.md': clean });
    cleanupDeadFragmentImports({ groupsDir });
    const out = fs.readFileSync(path.join(groupsDir, 'payne', 'CLAUDE.md'), 'utf8');
    expect(out).toBe(clean);
  });
});
