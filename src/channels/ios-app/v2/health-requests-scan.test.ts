import { describe, it, expect } from 'vitest';
import { mkdtempSync, mkdirSync, writeFileSync, utimesSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { healthRequestsDir, isSafeRequestId, scanHealthRequestFiles } from './health-requests-scan.js';

function dropDir(): string {
  const root = mkdtempSync(join(tmpdir(), 'hreq-'));
  const dir = healthRequestsDir(root);
  mkdirSync(dir, { recursive: true });
  return dir;
}

function drop(dir: string, name: string, body: unknown, ageMs = 0): void {
  const path = join(dir, name);
  writeFileSync(path, typeof body === 'string' ? body : JSON.stringify(body));
  if (ageMs) {
    const t = (Date.now() - ageMs) / 1000;
    utimesSync(path, t, t);
  }
}

describe('scanHealthRequestFiles', () => {
  it('turns a drop file into a request keyed by its basename', () => {
    const dir = dropDir();
    drop(dir, 'refresh_20260813.json', { from: '2026-07-30', to: '2026-08-13' });
    expect(scanHealthRequestFiles(dir)).toEqual([
      { requestId: 'refresh_20260813', from: '2026-07-30', to: '2026-08-13' },
    ]);
  });

  it('ignores the backlog rather than asking the phone for fifty windows', () => {
    // The directory holds every request written since June; nothing consumed
    // them before this scanner existed.
    const dir = dropDir();
    drop(dir, 'refresh_20260610.json', { from: '2026-05-28', to: '2026-06-10' }, 60 * 86_400_000);
    drop(dir, 'refresh_20260813.json', { from: '2026-07-30', to: '2026-08-13' });
    expect(scanHealthRequestFiles(dir).map((r) => r.requestId)).toEqual(['refresh_20260813']);
  });

  it('skips malformed, half-written and out-of-range files', () => {
    const dir = dropDir();
    drop(dir, 'a.json', '{ "from": "2026-08-01", '); // truncated
    drop(dir, 'b.json', { from: '2026-08-01' }); // no `to`
    drop(dir, 'c.json', { from: '01.08.2026', to: '2026-08-13' }); // not ISO
    drop(dir, 'd.json', { from: '2026-08-13', to: '2020-01-01' }); // reversed
    drop(dir, 'e.json', { from: '2000-01-01', to: '2026-08-13' }); // absurd span
    drop(dir, 'notes.txt', 'ignored');
    expect(scanHealthRequestFiles(dir)).toEqual([]);
  });

  it('returns nothing for a directory that does not exist', () => {
    expect(scanHealthRequestFiles(join(tmpdir(), 'no-such-dir-hreq'))).toEqual([]);
  });

  it('rejects ids that would escape the drop directory', () => {
    // The id round-trips through the client and is then joined into a path.
    expect(isSafeRequestId('refresh_20260813')).toBe(true);
    expect(isSafeRequestId('../../../etc/passwd')).toBe(false);
    expect(isSafeRequestId('a/b')).toBe(false);
    expect(isSafeRequestId('a.b')).toBe(false);
    expect(isSafeRequestId('')).toBe(false);
  });
});
