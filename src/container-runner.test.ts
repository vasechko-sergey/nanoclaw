import fs from 'fs';

import { afterEach, describe, expect, it } from 'vitest';

import { openContainerLogStream, resolveProviderName } from './container-runner.js';
import { sessionDir } from './session-manager.js';

describe('resolveProviderName', () => {
  it('prefers session over container config', () => {
    expect(resolveProviderName('codex', 'claude')).toBe('codex');
  });

  it('falls back to container config when session is null', () => {
    expect(resolveProviderName(null, 'opencode')).toBe('opencode');
  });

  it('defaults to claude when nothing is set', () => {
    expect(resolveProviderName(null, undefined)).toBe('claude');
  });

  it('lowercases the resolved name', () => {
    expect(resolveProviderName('CODEX', null)).toBe('codex');
    expect(resolveProviderName(null, 'Claude')).toBe('claude');
  });

  it('treats empty string as unset (falls through)', () => {
    expect(resolveProviderName('', 'opencode')).toBe('opencode');
    expect(resolveProviderName(null, '')).toBe('claude');
  });
});

describe('openContainerLogStream', () => {
  const ag = `test-clog-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
  const sid = 'sess-clog';

  afterEach(() => {
    fs.rmSync(sessionDir(ag, sid), { recursive: true, force: true });
  });

  it('appends a spawn marker and persists written stderr', async () => {
    const stream = openContainerLogStream(ag, sid, 'nanoclaw-test-1');
    expect(stream).not.toBeNull();
    stream!.write('boom: container died\n');
    await new Promise<void>((resolve) => stream!.end(resolve));

    const logPath = `${sessionDir(ag, sid)}/container.log`;
    const body = fs.readFileSync(logPath, 'utf8');
    expect(body).toContain('spawn nanoclaw-test-1');
    expect(body).toContain('boom: container died');
  });

  it('rotates to .log.1 when the existing file exceeds the size cap', async () => {
    const dir = sessionDir(ag, sid);
    fs.mkdirSync(dir, { recursive: true });
    const logPath = `${dir}/container.log`;
    // Pre-seed an oversized log (> 5MB cap).
    fs.writeFileSync(logPath, 'x'.repeat(6 * 1024 * 1024));

    const stream = openContainerLogStream(ag, sid, 'nanoclaw-test-2');
    await new Promise<void>((resolve) => stream!.end(resolve));

    // Old generation preserved as .log.1; fresh .log starts with the marker.
    expect(fs.existsSync(`${logPath}.1`)).toBe(true);
    expect(fs.statSync(`${logPath}.1`).size).toBeGreaterThan(5 * 1024 * 1024);
    const fresh = fs.readFileSync(logPath, 'utf8');
    expect(fresh).toContain('spawn nanoclaw-test-2');
    expect(fresh.length).toBeLessThan(1024);
  });
});
