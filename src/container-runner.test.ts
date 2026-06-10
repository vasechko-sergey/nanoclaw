import fs from 'fs';

import { afterEach, describe, expect, it } from 'vitest';

import { clearContinuationIfHeadless, openContainerLogStream, resolveProviderName } from './container-runner.js';
import { initSessionFolder, openOutboundDbRw, outboundDbPath, sessionDir } from './session-manager.js';
import type { Session } from './types.js';

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

  it('clearContinuationIfHeadless: noop for sessions with messaging_group_id', () => {
    const ag2 = `test-cont-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
    const sid2 = 'sess-interactive';
    initSessionFolder(ag2, sid2);
    try {
      const db = openOutboundDbRw(ag2, sid2);
      db.exec(`CREATE TABLE IF NOT EXISTS session_state (
        key TEXT PRIMARY KEY, value TEXT NOT NULL, updated_at TEXT NOT NULL DEFAULT ''
      )`);
      db.exec(
        `INSERT INTO session_state (key, value, updated_at) VALUES ('continuation:claude', 'KEEP_ME', '')`,
      );
      db.close();

      const interactive: Session = {
        id: sid2,
        agent_group_id: ag2,
        messaging_group_id: 'mg-x',
        thread_id: null,
        agent_provider: null,
        status: 'active',
        container_status: 'stopped',
        last_active: null,
        created_at: new Date().toISOString(),
      };
      clearContinuationIfHeadless(interactive);

      const verify = openOutboundDbRw(ag2, sid2);
      const row = verify.prepare("SELECT value FROM session_state WHERE key='continuation:claude'").get() as
        | { value: string }
        | undefined;
      verify.close();
      expect(row?.value).toBe('KEEP_ME');
    } finally {
      fs.rmSync(sessionDir(ag2, sid2), { recursive: true, force: true });
    }
  });

  it('clearContinuationIfHeadless: wipes continuation rows when messaging_group_id is null', () => {
    const ag2 = `test-cont-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
    const sid2 = 'sess-headless';
    initSessionFolder(ag2, sid2);
    try {
      const db = openOutboundDbRw(ag2, sid2);
      db.exec(`CREATE TABLE IF NOT EXISTS session_state (
        key TEXT PRIMARY KEY, value TEXT NOT NULL, updated_at TEXT NOT NULL DEFAULT ''
      )`);
      db.exec(`INSERT INTO session_state (key, value, updated_at) VALUES
        ('continuation:claude', 'OLD_CLAUDE', ''),
        ('continuation:codex',  'OLD_CODEX',  ''),
        ('other_key',           'PRESERVE',   '')`);
      db.close();

      const headless: Session = {
        id: sid2,
        agent_group_id: ag2,
        messaging_group_id: null,
        thread_id: null,
        agent_provider: null,
        status: 'active',
        container_status: 'stopped',
        last_active: null,
        created_at: new Date().toISOString(),
      };
      clearContinuationIfHeadless(headless);

      const verify = openOutboundDbRw(ag2, sid2);
      const rows = verify.prepare('SELECT key, value FROM session_state ORDER BY key').all() as Array<{
        key: string;
        value: string;
      }>;
      verify.close();
      // continuation:* rows gone, unrelated keys retained.
      expect(rows.map((r) => r.key)).toEqual(['other_key']);
      expect(rows[0].value).toBe('PRESERVE');
    } finally {
      fs.rmSync(sessionDir(ag2, sid2), { recursive: true, force: true });
    }
  });

  it('clearContinuationIfHeadless: silently skips when outbound.db does not exist yet', () => {
    const ag2 = `test-cont-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
    const sid2 = 'sess-fresh-headless';
    // No initSessionFolder — outbound.db will not exist.
    const headless: Session = {
      id: sid2,
      agent_group_id: ag2,
      messaging_group_id: null,
      thread_id: null,
      agent_provider: null,
      status: 'active',
      container_status: 'stopped',
      last_active: null,
      created_at: new Date().toISOString(),
    };
    // Should not throw.
    expect(() => clearContinuationIfHeadless(headless)).not.toThrow();
    expect(fs.existsSync(outboundDbPath(ag2, sid2))).toBe(false);
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
