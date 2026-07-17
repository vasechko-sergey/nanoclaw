import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';
import fs from 'fs';
import os from 'os';
import path from 'path';

import { log } from './log.js';
import { projectPublicProfiles, projectAllPublicProfiles } from './public-profiles.js';

let tmp: string;
let agentsDir: string;

beforeEach(() => {
  tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'profiles-'));
  // No descriptors placed here by default — the pre-existing suites below don't
  // care about the fragment-contract check, so an empty dir keeps every lookup
  // a clean "no descriptor" miss.
  agentsDir = fs.mkdtempSync(path.join(os.tmpdir(), 'agents-'));
});
afterEach(() => {
  fs.rmSync(tmp, { recursive: true, force: true });
  fs.rmSync(agentsDir, { recursive: true, force: true });
  vi.restoreAllMocks();
});

function writePublic(folder: string, body: string): void {
  const dir = path.join(tmp, folder, 'memories');
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(path.join(dir, 'public.md'), body);
}

describe('projectPublicProfiles', () => {
  it('projects each group public.md to global/profiles/<folder>.md', () => {
    writePublic('greg', '# greg\nreadiness: 72\n');
    const n = projectPublicProfiles(tmp, agentsDir);
    expect(n).toBe(1);
    expect(fs.readFileSync(path.join(tmp, 'global', 'profiles', 'greg.md'), 'utf8')).toBe('# greg\nreadiness: 72\n');
  });

  it('skips the reserved global folder', () => {
    fs.mkdirSync(path.join(tmp, 'global', 'memories'), { recursive: true });
    fs.writeFileSync(path.join(tmp, 'global', 'memories', 'public.md'), 'nope');
    projectPublicProfiles(tmp, agentsDir);
    expect(fs.existsSync(path.join(tmp, 'global', 'profiles', 'global.md'))).toBe(false);
  });

  it('skips groups with no public.md', () => {
    fs.mkdirSync(path.join(tmp, 'payne', 'memories'), { recursive: true });
    expect(projectPublicProfiles(tmp, agentsDir)).toBe(0);
  });

  it('does not rewrite unchanged content (hash-gated)', () => {
    writePublic('greg', 'same');
    expect(projectPublicProfiles(tmp, agentsDir)).toBe(1);
    expect(projectPublicProfiles(tmp, agentsDir)).toBe(0);
  });

  it('rewrites when content changes', () => {
    writePublic('greg', 'v1');
    projectPublicProfiles(tmp, agentsDir);
    writePublic('greg', 'v2');
    expect(projectPublicProfiles(tmp, agentsDir)).toBe(1);
    expect(fs.readFileSync(path.join(tmp, 'global', 'profiles', 'greg.md'), 'utf8')).toBe('v2');
  });
});

describe('projectAllPublicProfiles', () => {
  it('projects each person into their own global/profiles with per-person isolation', () => {
    // Set up user-memory base with two person dirs
    const userMemoryBase = path.join(tmp, 'user-memory');
    fs.mkdirSync(userMemoryBase, { recursive: true });

    // owner/greg/memories/public.md
    const ownerGregDir = path.join(userMemoryBase, 'owner', 'greg', 'memories');
    fs.mkdirSync(ownerGregDir, { recursive: true });
    fs.writeFileSync(path.join(ownerGregDir, 'public.md'), '# greg owner\nreadiness: 80\n');

    // p2/greg/memories/public.md — different content, same agent folder name
    const p2GregDir = path.join(userMemoryBase, 'p2', 'greg', 'memories');
    fs.mkdirSync(p2GregDir, { recursive: true });
    fs.writeFileSync(path.join(p2GregDir, 'public.md'), '# greg p2\nreadiness: 60\n');

    const n = projectAllPublicProfiles(userMemoryBase, agentsDir);
    // Two fragments written (one per person)
    expect(n).toBe(2);

    // owner sees only owner's content
    const ownerProfile = fs.readFileSync(path.join(userMemoryBase, 'owner', 'global', 'profiles', 'greg.md'), 'utf8');
    expect(ownerProfile).toBe('# greg owner\nreadiness: 80\n');

    // p2 sees only p2's content — proving per-person isolation
    const p2Profile = fs.readFileSync(path.join(userMemoryBase, 'p2', 'global', 'profiles', 'greg.md'), 'utf8');
    expect(p2Profile).toBe('# greg p2\nreadiness: 60\n');

    // p2's content never leaked into owner's dir
    expect(ownerProfile).not.toContain('p2');
    // owner's content never leaked into p2's dir
    expect(p2Profile).not.toContain('owner');
  });

  it('returns 0 when user-memory base does not exist', () => {
    const missing = path.join(tmp, 'nonexistent-user-memory');
    expect(projectAllPublicProfiles(missing, agentsDir)).toBe(0);
  });
});

/**
 * `mkPersonRoot` builds a bare person tree straight from a folder→body map,
 * skipping `writePublic`'s single-folder-at-a-time calls when a test wants
 * several agents (or none) laid out in one line.
 */
function mkPersonRoot(fragments: Record<string, string>): string {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'person-'));
  for (const [folder, body] of Object.entries(fragments)) {
    const p = path.join(tmp, folder, 'memories');
    fs.mkdirSync(p, { recursive: true });
    fs.writeFileSync(path.join(p, 'public.md'), body);
  }
  return tmp;
}

describe('fragment contract validation', () => {
  function withDescriptor(agentsDir: string, folder: string, publishes: unknown): void {
    fs.mkdirSync(path.join(agentsDir, folder), { recursive: true });
    fs.writeFileSync(path.join(agentsDir, folder, 'agent.json'), JSON.stringify({ publishes }));
  }

  it('warns when a declared non-optional field is missing from the body', () => {
    const tmp = mkPersonRoot({ greg: '**Готовность:** 69/100' });
    const agentsDir = fs.mkdtempSync(path.join(os.tmpdir(), 'agents-'));
    withDescriptor(agentsDir, 'greg', { desc: 'd', fields: { Готовность: 'N/100', Тренд: 'строка' } });
    const spy = vi.spyOn(log, 'warn');
    projectPublicProfiles(tmp, agentsDir);
    expect(spy).toHaveBeenCalledWith(
      'Fragment is missing declared fields',
      expect.objectContaining({ folder: 'greg', missing: ['Тренд'] }),
    );
  });

  it('does not warn for an optional field', () => {
    const tmp = mkPersonRoot({ greg: '**Готовность:** 69/100' });
    const agentsDir = fs.mkdtempSync(path.join(os.tmpdir(), 'agents-'));
    withDescriptor(agentsDir, 'greg', {
      desc: 'd',
      fields: { Готовность: 'N/100', 'Состав тела': 'вес' },
      optional: ['Состав тела'],
    });
    const spy = vi.spyOn(log, 'warn');
    projectPublicProfiles(tmp, agentsDir);
    expect(spy).not.toHaveBeenCalled();
  });

  it('still projects the fragment when a field is missing — warn, never block', () => {
    const tmp = mkPersonRoot({ greg: '**Готовность:** 69/100' });
    const agentsDir = fs.mkdtempSync(path.join(os.tmpdir(), 'agents-'));
    withDescriptor(agentsDir, 'greg', { desc: 'd', fields: { Тренд: 'строка' } });
    expect(projectPublicProfiles(tmp, agentsDir)).toBe(1);
    expect(fs.existsSync(path.join(tmp, 'global', 'profiles', 'greg.md'))).toBe(true);
  });

  it('is silent for an agent with no descriptor', () => {
    const tmp = mkPersonRoot({ greg: '**Готовность:** 69/100' });
    const agentsDir = fs.mkdtempSync(path.join(os.tmpdir(), 'agents-'));
    const spy = vi.spyOn(log, 'warn');
    expect(projectPublicProfiles(tmp, agentsDir)).toBe(1);
    expect(spy).not.toHaveBeenCalled();
  });

  it('does not re-warn while the fragment is unchanged (hash gate)', () => {
    const tmp = mkPersonRoot({ greg: '**Готовность:** 69/100' });
    const agentsDir = fs.mkdtempSync(path.join(os.tmpdir(), 'agents-'));
    withDescriptor(agentsDir, 'greg', { desc: 'd', fields: { Тренд: 'строка' } });
    const spy = vi.spyOn(log, 'warn');
    projectPublicProfiles(tmp, agentsDir);
    projectPublicProfiles(tmp, agentsDir);
    // A 60s sweep must not emit 1440 warns/day for one stale fragment.
    expect(spy).toHaveBeenCalledTimes(1);
  });
});
