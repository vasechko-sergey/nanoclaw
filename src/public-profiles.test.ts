import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import fs from 'fs';
import os from 'os';
import path from 'path';

import { projectPublicProfiles } from './public-profiles.js';

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
    expect(
      fs.readFileSync(path.join(tmp, 'global', 'profiles', 'greg.md'), 'utf8'),
    ).toBe('# greg\nreadiness: 72\n');
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
    expect(
      fs.readFileSync(path.join(tmp, 'global', 'profiles', 'greg.md'), 'utf8'),
    ).toBe('v2');
  });
});
