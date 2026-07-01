import fs from 'fs';
import os from 'os';
import path from 'path';

import { afterEach, beforeEach, describe, expect, it } from 'vitest';

import {
  buildMounts,
  clearContinuationIfHeadless,
  isGlobalMemoryWriter,
  openContainerLogStream,
  resolveProviderName,
} from './container-runner.js';
import { DATA_DIR, GROUPS_DIR, OWNER_PERSON_KEY } from './config.js';
import { initTestDb, closeDb, runMigrations, createAgentGroup, createSession } from './db/index.js';
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

describe('isGlobalMemoryWriter', () => {
  it('grants write only to the folder named in .writer', () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'nclaw-gw-'));
    try {
      fs.writeFileSync(path.join(dir, '.writer'), 'jarvis\n');
      expect(isGlobalMemoryWriter(dir, 'jarvis')).toBe(true);
      expect(isGlobalMemoryWriter(dir, 'greg')).toBe(false);
    } finally {
      fs.rmSync(dir, { recursive: true, force: true });
    }
  });

  it('grants write to nobody when .writer is missing, empty, or whitespace', () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'nclaw-gw-'));
    try {
      // missing
      expect(isGlobalMemoryWriter(dir, 'jarvis')).toBe(false);
      // whitespace-only
      fs.writeFileSync(path.join(dir, '.writer'), '   \n');
      expect(isGlobalMemoryWriter(dir, 'jarvis')).toBe(false);
    } finally {
      fs.rmSync(dir, { recursive: true, force: true });
    }
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
      db.exec(`INSERT INTO session_state (key, value, updated_at) VALUES ('continuation:claude', 'KEEP_ME', '')`);
      db.close();

      const interactive: Session = {
        id: sid2,
        agent_group_id: ag2,
        messaging_group_id: 'mg-x',
        thread_id: null,
        owner_key: null,
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
        owner_key: null,
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
      owner_key: null,
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

const ISO_AG = 'ag-test-iso';
const ISO_FOLDER = 'test-iso-mounts'; // throwaway — never a real agent folder

function mountsFor(ownerKey: string | null) {
  const agentGroup = { id: ISO_AG, name: 'Iso', folder: ISO_FOLDER, agent_provider: null, created_at: 'now' };
  const session = {
    id: 'sess-iso',
    agent_group_id: ISO_AG,
    messaging_group_id: null,
    thread_id: null,
    owner_key: ownerKey,
    agent_provider: null,
    status: 'active' as const,
    container_status: 'stopped' as const,
    last_active: null,
    created_at: 'now',
  };
  const cfg = { provider: 'claude', skills: [] as string[], additionalMounts: [] } as any;
  return buildMounts(agentGroup as any, session as any, cfg, {});
}

describe('buildMounts owner isolation', () => {
  beforeEach(() => {
    const db = initTestDb();
    runMigrations(db);
    createAgentGroup({ id: ISO_AG, name: 'Iso', folder: ISO_FOLDER, agent_provider: null, created_at: 'now' });
  });
  afterEach(() => {
    closeDb();
    fs.rmSync(path.join(GROUPS_DIR, ISO_FOLDER), { recursive: true, force: true });
    fs.rmSync(path.join(DATA_DIR, 'user-memory', 'isomnt', ISO_FOLDER), { recursive: true, force: true });
    fs.rmSync(path.join(DATA_DIR, 'user-memory', OWNER_PERSON_KEY, ISO_FOLDER), { recursive: true, force: true });
    fs.rmSync(path.join(DATA_DIR, 'user-memory', 'isomnt', 'global'), { recursive: true, force: true });
    fs.rmSync(path.join(DATA_DIR, 'user-memory', 'isomnt', 'shared'), { recursive: true, force: true });
    fs.rmSync(path.join(DATA_DIR, 'v2-sessions', ISO_AG), { recursive: true, force: true });
    fs.rmSync(path.join(process.cwd(), 'agents', ISO_FOLDER), { recursive: true, force: true });
  });

  it('mounts the agent dir (RW) + .claude from the session owner tree, never another person', () => {
    const mounts = mountsFor('isomnt');
    const isoRoot = path.join(DATA_DIR, 'user-memory', 'isomnt');
    // The whole /workspace/agent working dir is the per-person WRITABLE base —
    // all agent data (memories, nutrition, anything it creates) lands here.
    const agentMount = mounts.find((m) => m.containerPath === '/workspace/agent');
    expect(agentMount?.hostPath).toBe(path.join(isoRoot, ISO_FOLDER));
    expect(agentMount?.readonly).toBe(false);
    const claudeMount = mounts.find((m) => m.containerPath === '/home/node/.claude');
    expect(claudeMount?.hostPath).toBe(path.join(isoRoot, ISO_FOLDER, '.claude'));
    // No mount may point under any OTHER person's tree.
    const ownerRoot = path.join(DATA_DIR, 'user-memory', OWNER_PERSON_KEY);
    expect(mounts.some((m) => m.hostPath.startsWith(ownerRoot + path.sep))).toBe(false);
  });

  it('makes the whole agent dir writable; syncs ALL shared code, excludes secrets', () => {
    // Seed shared code: a top-level file, a ROOT code file (proves the whole dir
    // is synced, not a fixed item-list), a secret .env, and a template.
    const gdir = path.join(GROUPS_DIR, ISO_FOLDER);
    fs.mkdirSync(path.join(gdir, 'scripts'), { recursive: true });
    fs.writeFileSync(path.join(gdir, 'CLAUDE.md'), '# code');
    fs.writeFileSync(path.join(gdir, 'analyze.js'), '// root code');
    fs.writeFileSync(path.join(gdir, 'scripts', '.env'), 'SECRET=1');
    fs.writeFileSync(path.join(gdir, 'scripts', '.env.example'), 'SECRET=');
    const mounts = mountsFor('isomnt');
    // The agent dir is writable; NO nested read-only mounts — whole scope is RW.
    const agentMount = mounts.find((m) => m.containerPath === '/workspace/agent');
    expect(agentMount?.readonly).toBe(false);
    const nestedRo = mounts.filter(
      (m) => m.containerPath.startsWith('/workspace/agent/') && m.containerPath !== '/workspace/agent' && m.readonly,
    );
    expect(nestedRo).toEqual([]);
    const mem = path.join(DATA_DIR, 'user-memory', 'isomnt', ISO_FOLDER);
    // All code synced (top-level AND root files), template kept.
    expect(fs.readFileSync(path.join(mem, 'CLAUDE.md'), 'utf8')).toBe('# code');
    expect(fs.readFileSync(path.join(mem, 'analyze.js'), 'utf8')).toBe('// root code');
    expect(fs.existsSync(path.join(mem, 'scripts', '.env.example'))).toBe(true);
    // Secret .env is NEVER synced from the shared source.
    expect(fs.existsSync(path.join(mem, 'scripts', '.env'))).toBe(false);
  });

  it('never overwrites or leaks a per-person scripts/.env', () => {
    const gdir = path.join(GROUPS_DIR, ISO_FOLDER);
    fs.mkdirSync(path.join(gdir, 'scripts'), { recursive: true });
    fs.writeFileSync(path.join(gdir, 'scripts', '.env'), 'OWNER_SECRET=1'); // owner's, in shared source
    // A different person already has their OWN .env in their per-person tree.
    const mem = path.join(DATA_DIR, 'user-memory', 'isomnt', ISO_FOLDER);
    fs.mkdirSync(path.join(mem, 'scripts'), { recursive: true });
    fs.writeFileSync(path.join(mem, 'scripts', '.env'), 'HER_SECRET=1');
    mountsFor('isomnt');
    // Her .env is untouched — the shared (owner's) .env never overwrote it.
    expect(fs.readFileSync(path.join(mem, 'scripts', '.env'), 'utf8')).toBe('HER_SECRET=1');
  });

  it('mounts the shared wiki RW for every agent, under the owner tree', () => {
    const mounts = mountsFor('isomnt');
    const shared = mounts.find((m) => m.containerPath === '/workspace/shared');
    expect(shared?.hostPath).toBe(path.join(DATA_DIR, 'user-memory', 'isomnt', 'shared'));
    expect(shared?.readonly).toBe(false);
  });

  it('falls back to OWNER_PERSON_KEY when owner_key is null', () => {
    const mounts = mountsFor(null);
    const agentMount = mounts.find((m) => m.containerPath === '/workspace/agent');
    expect(agentMount?.hostPath).toBe(path.join(DATA_DIR, 'user-memory', OWNER_PERSON_KEY, ISO_FOLDER));
    // The shared mount resolves through the same ownerKey fallback.
    const sharedMount = mounts.find((m) => m.containerPath === '/workspace/shared');
    expect(sharedMount?.hostPath).toBe(path.join(DATA_DIR, 'user-memory', OWNER_PERSON_KEY, 'shared'));
  });

  it('shared-code model (agents/<folder> present): MOUNTS code instead of copying', () => {
    // Seed the shared per-agent code root: identity + a skill + scripts dir.
    const agentDir = path.join(process.cwd(), 'agents', ISO_FOLDER);
    fs.mkdirSync(path.join(agentDir, 'skills', 'demo'), { recursive: true });
    fs.writeFileSync(path.join(agentDir, 'skills', 'demo', 'SKILL.md'), '# demo');
    fs.mkdirSync(path.join(agentDir, 'scripts'), { recursive: true });
    fs.writeFileSync(path.join(agentDir, 'CLAUDE.md'), '# identity');
    // The person's own secret lives in their tree, overlaid over shared scripts/.
    const mem = path.join(DATA_DIR, 'user-memory', 'isomnt', ISO_FOLDER);
    fs.mkdirSync(mem, { recursive: true });
    fs.writeFileSync(path.join(mem, '.env'), 'SECRET=1');

    const mounts = mountsFor('isomnt');
    const by = (p: string) => mounts.find((m) => m.containerPath === p);

    // Per-person data base stays RW; code was NOT copied into it.
    expect(by('/workspace/agent')).toMatchObject({ hostPath: mem, readonly: false });
    expect(fs.existsSync(path.join(mem, 'CLAUDE.md'))).toBe(false);
    // Identity RO from the single shared source.
    expect(by('/workspace/agent/CLAUDE.md')).toMatchObject({ hostPath: path.join(agentDir, 'CLAUDE.md'), readonly: true });
    // skills + scripts RW from the shared source → the agent's edits persist.
    expect(by('/workspace/agent/skills')).toMatchObject({ hostPath: path.join(agentDir, 'skills'), readonly: false });
    expect(by('/workspace/agent/scripts')).toMatchObject({ hostPath: path.join(agentDir, 'scripts'), readonly: false });
    // Per-person .env overlays the shared scripts/ so the secret stays private.
    expect(by('/workspace/agent/scripts/.env')).toMatchObject({ hostPath: path.join(mem, '.env'), readonly: false });
  });

  it('shared-code model: symlinks per-agent skills from agents/<folder>/skills', () => {
    const agentDir = path.join(process.cwd(), 'agents', ISO_FOLDER);
    fs.mkdirSync(path.join(agentDir, 'skills', 'demo'), { recursive: true });
    fs.writeFileSync(path.join(agentDir, 'skills', 'demo', 'SKILL.md'), '# demo');
    mountsFor('isomnt');
    const link = path.join(DATA_DIR, 'user-memory', 'isomnt', ISO_FOLDER, '.claude', 'skills', 'demo');
    expect(fs.readlinkSync(link)).toBe('/workspace/agent/skills/demo');
  });
});

// Recurring tasks are consolidated into the owner's headless session. An
// interactive session must mount that session's folder read-only so list_tasks
// inside the container can see them (the container only ever has its OWN session
// folder otherwise). See src/modules/scheduling/actions.ts.
const HTV_AG = 'ag-test-htv';
const HTV_FOLDER = 'test-htv-mounts';

describe('buildMounts headless task visibility', () => {
  const cfg = { provider: 'claude', skills: [] as string[], additionalMounts: [] } as any;

  function htvSession(id: string, messagingGroupId: string | null): Session {
    return {
      id,
      agent_group_id: HTV_AG,
      messaging_group_id: messagingGroupId,
      thread_id: null,
      owner_key: 'htvowner',
      agent_provider: null,
      status: 'active',
      container_status: 'stopped',
      last_active: null,
      created_at: 'now',
    };
  }

  function buildFor(session: Session) {
    const agentGroup = { id: HTV_AG, name: 'Htv', folder: HTV_FOLDER, agent_provider: null, created_at: 'now' };
    return buildMounts(agentGroup as any, session as any, cfg, {});
  }

  beforeEach(() => {
    const db = initTestDb();
    runMigrations(db);
    createAgentGroup({ id: HTV_AG, name: 'Htv', folder: HTV_FOLDER, agent_provider: null, created_at: 'now' });
  });
  afterEach(() => {
    closeDb();
    fs.rmSync(path.join(GROUPS_DIR, HTV_FOLDER), { recursive: true, force: true });
    fs.rmSync(path.join(DATA_DIR, 'user-memory', 'htvowner'), { recursive: true, force: true });
    fs.rmSync(path.join(DATA_DIR, 'v2-sessions', HTV_AG), { recursive: true, force: true });
  });

  it('mounts the owner headless session folder read-only at /workspace/.headless', () => {
    createSession(htvSession('sess-htv-headless', null));
    const mounts = buildFor(htvSession('sess-htv-interactive', 'mg-htv'));
    const m = mounts.find((x) => x.containerPath === '/workspace/.headless');
    expect(m?.hostPath).toBe(sessionDir(HTV_AG, 'sess-htv-headless'));
    expect(m?.readonly).toBe(true);
  });

  it('does NOT mount .headless for the headless session itself (no self-mount)', () => {
    createSession(htvSession('sess-htv-headless', null));
    const mounts = buildFor(htvSession('sess-htv-headless', null));
    expect(mounts.find((x) => x.containerPath === '/workspace/.headless')).toBeUndefined();
  });

  it('does NOT mount .headless when the owner has no headless session', () => {
    const mounts = buildFor(htvSession('sess-htv-interactive', 'mg-htv'));
    expect(mounts.find((x) => x.containerPath === '/workspace/.headless')).toBeUndefined();
  });

  it("does NOT mount another person's headless session", () => {
    // Headless belongs to a DIFFERENT owner — must not leak into this person's container.
    createSession({ ...htvSession('sess-htv-headless-other', null), owner_key: 'someoneelse' });
    const mounts = buildFor(htvSession('sess-htv-interactive', 'mg-htv'));
    expect(mounts.find((x) => x.containerPath === '/workspace/.headless')).toBeUndefined();
  });
});
