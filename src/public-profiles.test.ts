import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import fs from 'fs';
import os from 'os';
import path from 'path';

import { projectPublicProfiles, projectAllPublicProfiles } from './public-profiles.js';

let tmp: string;

beforeEach(() => {
  tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'profiles-'));
});
afterEach(() => {
  fs.rmSync(tmp, { recursive: true, force: true });
});

function writePublic(folder: string, body: string): void {
  const dir = path.join(tmp, folder, 'memories');
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(path.join(dir, 'public.md'), body);
}

describe('projectPublicProfiles', () => {
  it('projects each group public.md to global/profiles/<folder>.md', () => {
    writePublic('greg', '# greg\nreadiness: 72\n');
    const n = projectPublicProfiles(tmp);
    expect(n).toBe(1);
    expect(fs.readFileSync(path.join(tmp, 'global', 'profiles', 'greg.md'), 'utf8')).toBe('# greg\nreadiness: 72\n');
  });

  it('skips the reserved global folder', () => {
    fs.mkdirSync(path.join(tmp, 'global', 'memories'), { recursive: true });
    fs.writeFileSync(path.join(tmp, 'global', 'memories', 'public.md'), 'nope');
    projectPublicProfiles(tmp);
    expect(fs.existsSync(path.join(tmp, 'global', 'profiles', 'global.md'))).toBe(false);
  });

  it('skips groups with no public.md', () => {
    fs.mkdirSync(path.join(tmp, 'payne', 'memories'), { recursive: true });
    expect(projectPublicProfiles(tmp)).toBe(0);
  });

  it('does not rewrite unchanged content (hash-gated)', () => {
    writePublic('greg', 'same');
    expect(projectPublicProfiles(tmp)).toBe(1);
    expect(projectPublicProfiles(tmp)).toBe(0);
  });

  it('rewrites when content changes', () => {
    writePublic('greg', 'v1');
    projectPublicProfiles(tmp);
    writePublic('greg', 'v2');
    expect(projectPublicProfiles(tmp)).toBe(1);
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

    const n = projectAllPublicProfiles(userMemoryBase);
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
    expect(projectAllPublicProfiles(missing)).toBe(0);
  });
});
