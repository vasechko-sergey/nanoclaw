/**
 * Characterization tests for src/session-manager.ts.
 *
 * GOAL: lock down CURRENT behavior as a regression net. These assert what the
 * code does today (warts included), not what it ideally should do. Surprising
 * or fragile behavior is flagged with `// characterization` comments.
 *
 * Scope of what we exercise here:
 *   - Pure path-resolution helpers (sessionDir / inboundDbPath / ... ).
 *   - Two-DB lifecycle: initSessionFolder, open*Db modes, seq parity.
 *   - writeSessionMessage / writeOutboundDirect seq assignment (host = EVEN).
 *   - Attachment path safety on both inbound (extractAttachmentFiles, reached
 *     via writeSessionMessage) and outbound (readOutboxFiles / clearOutbox):
 *     realpath containment, symlink rejection, traversal rejection.
 *
 * Real DATA_DIR note: DATA_DIR is frozen at module load from process.cwd(), so
 * sessionDir() always resolves under <repo>/data/v2-sessions/. We can't redirect
 * it without mocking, so instead every test uses a unique throwaway
 * agentGroupId (TEST_AG prefix) and only ever removes ITS OWN subtree in
 * afterEach. We never touch sibling (real) session dirs.
 */
import Database from 'better-sqlite3';
import fs from 'fs';
import path from 'path';
import { describe, it, expect, beforeEach, afterEach } from 'vitest';

import { initTestDb, closeDb, runMigrations, createAgentGroup, createSession, getSession } from './db/index.js';
import { updateSession } from './db/sessions.js';
import { insertTask } from './modules/scheduling/db.js';
import {
  sessionsBaseDir,
  sessionDir,
  inboundDbPath,
  outboundDbPath,
  heartbeatPath,
  sessionDbPath,
  initSessionFolder,
  openInboundDb,
  openOutboundDb,
  openOutboundDbRw,
  writeSessionMessage,
  writeOutboundDirect,
  readOutboxFiles,
  clearOutbox,
  resolveSession,
} from './session-manager.js';
import { OWNER_PERSON_KEY } from './config.js';

function now() {
  return new Date().toISOString();
}

// Per-test unique agent-group id so our session tree is fully isolated from
// any real sessions living under data/v2-sessions/.
let TEST_AG: string;
const SESSION_ID = 'sess-test';

function seedAgentAndSession() {
  // writeSessionMessage / resolveSession touch the central DB (updateSession,
  // createSession). Provide a real backing row so those writes succeed.
  createAgentGroup({
    id: TEST_AG,
    name: 'Test Agent',
    folder: TEST_AG, // folder is UNIQUE; reuse the unique ag id
    agent_provider: null,
    created_at: now(),
  });
  createSession({
    id: SESSION_ID,
    agent_group_id: TEST_AG,
    messaging_group_id: null,
    thread_id: null,
    owner_key: null,
    agent_provider: null,
    status: 'active',
    container_status: 'stopped',
    last_active: null,
    created_at: now(),
  });
}

beforeEach(() => {
  TEST_AG = `test-sm-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
  const db = initTestDb();
  runMigrations(db);
});

afterEach(() => {
  // Remove ONLY this test's agent-group subtree, never the whole base dir.
  const dir = path.join(sessionsBaseDir(), TEST_AG);
  if (fs.existsSync(dir)) fs.rmSync(dir, { recursive: true, force: true });
  closeDb();
});

// ── Pure path helpers ──

describe('path helpers', () => {
  it('sessionsBaseDir is <DATA_DIR>/v2-sessions', () => {
    expect(sessionsBaseDir().endsWith(path.join('data', 'v2-sessions'))).toBe(true);
  });

  it('sessionDir nests agentGroupId then sessionId under the base', () => {
    expect(sessionDir('ag', 'sess')).toBe(path.join(sessionsBaseDir(), 'ag', 'sess'));
  });

  it('inboundDbPath / outboundDbPath / heartbeatPath sit inside the session dir', () => {
    const d = sessionDir('ag', 'sess');
    expect(inboundDbPath('ag', 'sess')).toBe(path.join(d, 'inbound.db'));
    expect(outboundDbPath('ag', 'sess')).toBe(path.join(d, 'outbound.db'));
    expect(heartbeatPath('ag', 'sess')).toBe(path.join(d, '.heartbeat'));
  });

  it('deprecated sessionDbPath aliases inboundDbPath', () => {
    // characterization: sessionDbPath is the old single-DB name, now an alias.
    expect(sessionDbPath('ag', 'sess')).toBe(inboundDbPath('ag', 'sess'));
  });

  it('path helpers are pure — no filesystem side effects', () => {
    sessionDir(TEST_AG, SESSION_ID);
    inboundDbPath(TEST_AG, SESSION_ID);
    heartbeatPath(TEST_AG, SESSION_ID);
    expect(fs.existsSync(path.join(sessionsBaseDir(), TEST_AG))).toBe(false);
  });
});

// ── initSessionFolder + DB open modes ──

describe('initSessionFolder', () => {
  it('creates the session dir, the outbox subdir, and both DB files', () => {
    initSessionFolder(TEST_AG, SESSION_ID);

    const dir = sessionDir(TEST_AG, SESSION_ID);
    expect(fs.existsSync(dir)).toBe(true);
    expect(fs.existsSync(path.join(dir, 'outbox'))).toBe(true);
    expect(fs.existsSync(inboundDbPath(TEST_AG, SESSION_ID))).toBe(true);
    expect(fs.existsSync(outboundDbPath(TEST_AG, SESSION_ID))).toBe(true);
  });

  it('does NOT create the inbox dir up front (created lazily on first attachment)', () => {
    // characterization: outbox is pre-created, inbox is not.
    initSessionFolder(TEST_AG, SESSION_ID);
    expect(fs.existsSync(path.join(sessionDir(TEST_AG, SESSION_ID), 'inbox'))).toBe(false);
  });

  it('initializes inbound schema (messages_in) and outbound schema (messages_out, session_state)', () => {
    initSessionFolder(TEST_AG, SESSION_ID);

    const inDb = openInboundDb(TEST_AG, SESSION_ID);
    const inTables = (
      inDb.prepare("SELECT name FROM sqlite_master WHERE type='table'").all() as Array<{ name: string }>
    ).map((r) => r.name);
    inDb.close();
    expect(inTables).toContain('messages_in');
    expect(inTables).toContain('delivered');
    expect(inTables).toContain('destinations');
    expect(inTables).toContain('session_routing');

    const outDb = openOutboundDb(TEST_AG, SESSION_ID);
    const outTables = (
      outDb.prepare("SELECT name FROM sqlite_master WHERE type='table'").all() as Array<{ name: string }>
    ).map((r) => r.name);
    outDb.close();
    expect(outTables).toContain('messages_out');
    expect(outTables).toContain('processing_ack');
    expect(outTables).toContain('session_state');
  });

  it('uses journal_mode=DELETE on the inbound DB (load-bearing cross-mount pragma)', () => {
    // characterization: WAL would break host→guest visibility; DELETE is required.
    initSessionFolder(TEST_AG, SESSION_ID);
    const inDb = openInboundDb(TEST_AG, SESSION_ID);
    const mode = (inDb.pragma('journal_mode', { simple: true }) as string).toLowerCase();
    inDb.close();
    expect(mode).toBe('delete');
  });

  it('is idempotent — re-running over an existing folder does not throw', () => {
    initSessionFolder(TEST_AG, SESSION_ID);
    expect(() => initSessionFolder(TEST_AG, SESSION_ID)).not.toThrow();
  });
});

describe('openInboundDb migrates an existing session DB', () => {
  it('adds destinations.a2a_kinds to a session DB created before the column existed', () => {
    initSessionFolder(TEST_AG, SESSION_ID);

    // Rewind this session DB to the pre-a2a_kinds shape. `initSessionFolder`
    // ships the column via `CREATE TABLE IF NOT EXISTS`, which is exactly what
    // does NOT reach a table that already exists — so a real install upgraded
    // from an older build looks like this, not like a fresh schema.
    const raw = new Database(inboundDbPath(TEST_AG, SESSION_ID));
    raw.exec(`
      DROP TABLE destinations;
      CREATE TABLE destinations (
        name            TEXT PRIMARY KEY,
        display_name    TEXT,
        type            TEXT NOT NULL,
        channel_type    TEXT,
        platform_id     TEXT,
        agent_group_id  TEXT
      );
    `);
    raw.close();

    const db = openInboundDb(TEST_AG, SESSION_ID);
    const cols = (db.prepare("PRAGMA table_info('destinations')").all() as Array<{ name: string }>).map((c) => c.name);
    db.close();

    expect(cols).toContain('a2a_kinds');
  });
});

describe('openOutboundDb read-only vs openOutboundDbRw', () => {
  beforeEach(() => initSessionFolder(TEST_AG, SESSION_ID));

  it('openOutboundDb opens read-only — writes throw', () => {
    const db = openOutboundDb(TEST_AG, SESSION_ID);
    try {
      expect(() =>
        db
          .prepare(
            "INSERT INTO messages_out (id, seq, timestamp, kind, content) VALUES ('x', 1, datetime('now'), 'chat', '{}')",
          )
          .run(),
      ).toThrow();
    } finally {
      db.close();
    }
  });

  it('openOutboundDbRw permits writes', () => {
    const db = openOutboundDbRw(TEST_AG, SESSION_ID);
    try {
      expect(() =>
        db
          .prepare(
            "INSERT INTO messages_out (id, seq, timestamp, kind, content) VALUES ('x', 1, datetime('now'), 'chat', '{}')",
          )
          .run(),
      ).not.toThrow();
    } finally {
      db.close();
    }
  });
});

// ── writeSessionMessage: seq parity + monotonicity ──

describe('writeSessionMessage seq assignment (host = EVEN)', () => {
  beforeEach(() => {
    seedAgentAndSession();
    initSessionFolder(TEST_AG, SESSION_ID);
  });

  function readMessages() {
    const db = openInboundDb(TEST_AG, SESSION_ID);
    const rows = db.prepare('SELECT id, seq, status, trigger FROM messages_in ORDER BY seq ASC').all() as Array<{
      id: string;
      seq: number;
      status: string;
      trigger: number;
    }>;
    db.close();
    return rows;
  }

  function writeMsg(id: string) {
    writeSessionMessage(TEST_AG, SESSION_ID, {
      id,
      kind: 'chat',
      timestamp: now(),
      content: '{}',
    });
  }

  it('first message gets seq=2 (nextEvenSeq floors at 2)', () => {
    writeMsg('m1');
    const rows = readMessages();
    expect(rows).toHaveLength(1);
    expect(rows[0].seq).toBe(2);
  });

  it('subsequent host messages stay even and strictly increase by 2', () => {
    writeMsg('m1');
    writeMsg('m2');
    writeMsg('m3');
    const seqs = readMessages().map((r) => r.seq);
    expect(seqs).toEqual([2, 4, 6]);
    for (const s of seqs) expect(s % 2).toBe(0);
  });

  it("defaults status='pending' and trigger=1", () => {
    writeMsg('m1');
    const row = readMessages()[0];
    expect(row.status).toBe('pending');
    expect(row.trigger).toBe(1);
  });

  it('bumps the central-DB session last_active', () => {
    expect(getSession(SESSION_ID)!.last_active).toBeNull();
    writeMsg('m1');
    expect(getSession(SESSION_ID)!.last_active).not.toBeNull();
  });

  it('persists series_id = id for a freshly written row', () => {
    // characterization: insertMessage sets series_id to the message id.
    writeMsg('m1');
    const db = openInboundDb(TEST_AG, SESSION_ID);
    const row = db.prepare('SELECT series_id FROM messages_in WHERE id = ?').get('m1') as { series_id: string };
    db.close();
    expect(row.series_id).toBe('m1');
  });
});

// ── writeOutboundDirect: even seq via MAX+2 ──

describe('writeOutboundDirect seq assignment', () => {
  beforeEach(() => initSessionFolder(TEST_AG, SESSION_ID));

  function readOut() {
    const db = openOutboundDb(TEST_AG, SESSION_ID);
    const rows = db.prepare('SELECT id, seq FROM messages_out ORDER BY seq ASC').all() as Array<{
      id: string;
      seq: number;
    }>;
    db.close();
    return rows;
  }

  function writeOut(id: string) {
    writeOutboundDirect(TEST_AG, SESSION_ID, {
      id,
      kind: 'chat',
      platformId: null,
      channelType: null,
      threadId: null,
      content: 'denied',
    });
  }

  it('first direct outbound row gets seq=2 (COALESCE(MAX,0)+2)', () => {
    // characterization: empty table → MAX(seq) is COALESCEd to 0, so 0+2=2.
    writeOut('o1');
    const rows = readOut();
    expect(rows).toHaveLength(1);
    expect(rows[0].seq).toBe(2);
  });

  it('increments by 2 per call, staying even', () => {
    writeOut('o1');
    writeOut('o2');
    const seqs = readOut().map((r) => r.seq);
    expect(seqs).toEqual([2, 4]);
  });

  it('uses INSERT OR IGNORE — a duplicate id is silently dropped', () => {
    // characterization: second insert with same id is a no-op (no throw, no row).
    writeOut('dup');
    expect(() => writeOut('dup')).not.toThrow();
    expect(readOut()).toHaveLength(1);
  });
});

// ── Inbound attachment safety (via writeSessionMessage → extractAttachmentFiles) ──

describe('inbound attachment extraction + safety', () => {
  beforeEach(() => {
    seedAgentAndSession();
    initSessionFolder(TEST_AG, SESSION_ID);
  });

  function storedContent(id: string): string {
    const db = openInboundDb(TEST_AG, SESSION_ID);
    const row = db.prepare('SELECT content FROM messages_in WHERE id = ?').get(id) as { content: string };
    db.close();
    return row.content;
  }

  it('saves a base64 attachment to inbox/<msgId>/<name> and rewrites content with localPath', () => {
    const data = Buffer.from('hello world').toString('base64');
    writeSessionMessage(TEST_AG, SESSION_ID, {
      id: 'msg-att',
      kind: 'chat',
      timestamp: now(),
      content: JSON.stringify({ text: 'hi', attachments: [{ name: 'note.txt', data }] }),
    });

    const onDisk = path.join(sessionDir(TEST_AG, SESSION_ID), 'inbox', 'msg-att', 'note.txt');
    expect(fs.existsSync(onDisk)).toBe(true);
    expect(fs.readFileSync(onDisk, 'utf8')).toBe('hello world');

    const parsed = JSON.parse(storedContent('msg-att'));
    expect(parsed.attachments[0].localPath).toBe('inbox/msg-att/note.txt');
    expect(parsed.attachments[0].data).toBeUndefined(); // base64 stripped
    expect(parsed.attachments[0].name).toBe('note.txt');
  });

  it('saves an iOS-v2 attachment carrying bytes_base64 (not data) to inbox with localPath', () => {
    // The ios-app v2 protocol names the base64 field `bytes_base64`, not `data`.
    const bytes_base64 = Buffer.from('pdf-bytes').toString('base64');
    writeSessionMessage(TEST_AG, SESSION_ID, {
      id: 'msg-v2',
      kind: 'chat',
      timestamp: now(),
      content: JSON.stringify({
        text: 'Держи выписку',
        attachments: [{ name: 'Statement.pdf', mime_type: 'application/pdf', bytes_base64 }],
      }),
    });

    const onDisk = path.join(sessionDir(TEST_AG, SESSION_ID), 'inbox', 'msg-v2', 'Statement.pdf');
    expect(fs.existsSync(onDisk)).toBe(true);
    expect(fs.readFileSync(onDisk, 'utf8')).toBe('pdf-bytes');

    const parsed = JSON.parse(storedContent('msg-v2'));
    expect(parsed.attachments[0].localPath).toBe('inbox/msg-v2/Statement.pdf');
    expect(parsed.attachments[0].bytes_base64).toBeUndefined(); // base64 stripped from stored content
    expect(parsed.attachments[0].name).toBe('Statement.pdf');
  });

  it('leaves non-JSON content untouched', () => {
    writeSessionMessage(TEST_AG, SESSION_ID, {
      id: 'plain',
      kind: 'chat',
      timestamp: now(),
      content: 'just a string, not json',
    });
    expect(storedContent('plain')).toBe('just a string, not json');
  });

  it('leaves JSON without an attachments array untouched', () => {
    const content = JSON.stringify({ text: 'no attachments here', attachments: 'not-an-array' });
    writeSessionMessage(TEST_AG, SESSION_ID, { id: 'noatt', kind: 'chat', timestamp: now(), content });
    expect(storedContent('noatt')).toBe(content);
  });

  it('skips attachments whose data is not a string (no inbox dir created)', () => {
    const content = JSON.stringify({ attachments: [{ name: 'x.txt' /* no data */ }] });
    writeSessionMessage(TEST_AG, SESSION_ID, { id: 'nodata', kind: 'chat', timestamp: now(), content });
    // characterization: content is returned unchanged because nothing was saved.
    expect(storedContent('nodata')).toBe(content);
    expect(fs.existsSync(path.join(sessionDir(TEST_AG, SESSION_ID), 'inbox', 'nodata'))).toBe(false);
  });

  it('rejects an unsafe message id (traversal) — content unchanged, no escape write', () => {
    const data = Buffer.from('x').toString('base64');
    const content = JSON.stringify({ attachments: [{ name: 'a.txt', data }] });
    writeSessionMessage(TEST_AG, SESSION_ID, {
      id: '../escape',
      kind: 'chat',
      timestamp: now(),
      content,
    });
    // The bad id is still the PK of the stored row, but the attachment was NOT
    // extracted (content kept its base64 data, no file written outside).
    const db = openInboundDb(TEST_AG, SESSION_ID);
    const row = db.prepare('SELECT content FROM messages_in WHERE id = ?').get('../escape') as
      | { content: string }
      | undefined;
    db.close();
    expect(row).toBeDefined();
    expect(row!.content).toBe(content); // unchanged → extraction refused
    // characterization: the parent-relative path was never materialized.
    expect(fs.existsSync(path.join(sessionsBaseDir(), TEST_AG, 'escape'))).toBe(false);
  });

  it('rewrites a traversal-laden attachment NAME to a safe attachment-* fallback', () => {
    const data = Buffer.from('payload').toString('base64');
    const content = JSON.stringify({ attachments: [{ name: '../../etc/passwd', data }] });
    writeSessionMessage(TEST_AG, SESSION_ID, { id: 'badname', kind: 'chat', timestamp: now(), content });

    const parsed = JSON.parse(storedContent('badname'));
    // characterization: unsafe name is replaced with `attachment-<ts>`, kept
    // strictly inside inbox/<msgId>/.
    expect(parsed.attachments[0].name).toMatch(/^attachment-\d+$/);
    expect(parsed.attachments[0].localPath).toMatch(/^inbox\/badname\/attachment-\d+$/);
    const escaped = path.join(sessionsBaseDir(), 'etc', 'passwd');
    expect(fs.existsSync(escaped)).toBe(false);
  });

  it('refuses to write through a pre-placed symlink at the inbox dir (mkdir guard)', () => {
    // Simulate a compromised container pre-placing inbox/<msgId> as a symlink
    // pointing outside the session tree.
    const outsideTarget = fs.mkdtempSync(path.join(require('os').tmpdir(), 'sm-evil-'));
    const inboxRoot = path.join(sessionDir(TEST_AG, SESSION_ID), 'inbox');
    fs.mkdirSync(inboxRoot, { recursive: true });
    const linkPath = path.join(inboxRoot, 'evilmsg');
    fs.symlinkSync(outsideTarget, linkPath);

    const data = Buffer.from('attack').toString('base64');
    const content = JSON.stringify({ attachments: [{ name: 'pwn.txt', data }] });
    writeSessionMessage(TEST_AG, SESSION_ID, { id: 'evilmsg', kind: 'chat', timestamp: now(), content });

    // characterization: the symlinked dir is rejected, nothing written through it.
    expect(fs.existsSync(path.join(outsideTarget, 'pwn.txt'))).toBe(false);
    expect(storedContent('evilmsg')).toBe(content); // extraction refused → unchanged

    fs.rmSync(outsideTarget, { recursive: true, force: true });
  });

  it('refuses to overwrite an existing inbox file (wx exclusive create)', () => {
    // Pre-create the exact target file the host would write to.
    const inboxDir = path.join(sessionDir(TEST_AG, SESSION_ID), 'inbox', 'collide');
    fs.mkdirSync(inboxDir, { recursive: true });
    fs.writeFileSync(path.join(inboxDir, 'doc.txt'), 'ORIGINAL');

    const data = Buffer.from('REPLACEMENT').toString('base64');
    const content = JSON.stringify({ attachments: [{ name: 'doc.txt', data }] });
    writeSessionMessage(TEST_AG, SESSION_ID, { id: 'collide', kind: 'chat', timestamp: now(), content });

    // characterization: wx flag means the pre-existing file is preserved and
    // the attachment is skipped (content left unchanged, no localPath).
    expect(fs.readFileSync(path.join(inboxDir, 'doc.txt'), 'utf8')).toBe('ORIGINAL');
    expect(storedContent('collide')).toBe(content);
  });
});

// ── Outbound attachment safety: readOutboxFiles ──

describe('readOutboxFiles', () => {
  beforeEach(() => initSessionFolder(TEST_AG, SESSION_ID));

  function outboxDirFor(messageId: string): string {
    const d = path.join(sessionDir(TEST_AG, SESSION_ID), 'outbox', messageId);
    fs.mkdirSync(d, { recursive: true });
    return d;
  }

  it('returns files that exist inside outbox/<msgId>/', () => {
    const d = outboxDirFor('mo1');
    fs.writeFileSync(path.join(d, 'a.txt'), 'AAA');
    fs.writeFileSync(path.join(d, 'b.txt'), 'BBB');

    const files = readOutboxFiles(TEST_AG, SESSION_ID, 'mo1', ['a.txt', 'b.txt']);
    expect(files).toBeDefined();
    expect(files!.map((f) => f.filename).sort()).toEqual(['a.txt', 'b.txt']);
    const a = files!.find((f) => f.filename === 'a.txt')!;
    expect(a.data.toString('utf8')).toBe('AAA');
  });

  it('returns undefined when the outbox dir is missing', () => {
    expect(readOutboxFiles(TEST_AG, SESSION_ID, 'never-created', ['x.txt'])).toBeUndefined();
  });

  it('returns undefined when no requested file is actually on disk', () => {
    outboxDirFor('empty');
    expect(readOutboxFiles(TEST_AG, SESSION_ID, 'empty', ['missing.txt'])).toBeUndefined();
  });

  it('rejects an unsafe message id', () => {
    expect(readOutboxFiles(TEST_AG, SESSION_ID, '../escape', ['a.txt'])).toBeUndefined();
  });

  it('skips unsafe filenames but keeps safe siblings', () => {
    const d = outboxDirFor('mixed');
    fs.writeFileSync(path.join(d, 'ok.txt'), 'OK');
    const files = readOutboxFiles(TEST_AG, SESSION_ID, 'mixed', ['../etc/passwd', 'ok.txt']);
    expect(files).toBeDefined();
    expect(files!.map((f) => f.filename)).toEqual(['ok.txt']);
  });

  it('rejects a symlinked file inside the outbox dir, even if it resolves in-bounds', () => {
    // characterization: lstat catches the symlink and refuses it BEFORE realpath,
    // so even a link pointing at a sibling real file in the same dir is dropped.
    const d = outboxDirFor('symfile');
    fs.writeFileSync(path.join(d, 'real.txt'), 'REAL');
    fs.symlinkSync(path.join(d, 'real.txt'), path.join(d, 'link.txt'));
    const files = readOutboxFiles(TEST_AG, SESSION_ID, 'symfile', ['link.txt']);
    expect(files).toBeUndefined();
  });

  it('rejects when the outbox/<msgId> dir itself is a symlink', () => {
    const outsideTarget = fs.mkdtempSync(path.join(require('os').tmpdir(), 'sm-obx-'));
    fs.writeFileSync(path.join(outsideTarget, 'secret.txt'), 'SECRET');
    const outboxRoot = path.join(sessionDir(TEST_AG, SESSION_ID), 'outbox');
    fs.mkdirSync(outboxRoot, { recursive: true });
    fs.symlinkSync(outsideTarget, path.join(outboxRoot, 'linkdir'));

    const files = readOutboxFiles(TEST_AG, SESSION_ID, 'linkdir', ['secret.txt']);
    expect(files).toBeUndefined();

    fs.rmSync(outsideTarget, { recursive: true, force: true });
  });
});

// ── Outbound attachment safety: clearOutbox ──

describe('clearOutbox', () => {
  beforeEach(() => initSessionFolder(TEST_AG, SESSION_ID));

  it('removes an existing outbox/<msgId> directory', () => {
    const d = path.join(sessionDir(TEST_AG, SESSION_ID), 'outbox', 'done');
    fs.mkdirSync(d, { recursive: true });
    fs.writeFileSync(path.join(d, 'f.txt'), 'x');
    expect(fs.existsSync(d)).toBe(true);

    clearOutbox(TEST_AG, SESSION_ID, 'done');
    expect(fs.existsSync(d)).toBe(false);
  });

  it('is a no-op (no throw) when the dir does not exist', () => {
    expect(() => clearOutbox(TEST_AG, SESSION_ID, 'ghost')).not.toThrow();
  });

  it('refuses an unsafe message id (no throw, nothing removed)', () => {
    expect(() => clearOutbox(TEST_AG, SESSION_ID, '../escape')).not.toThrow();
  });

  it('refuses to follow + delete through a symlinked outbox/<msgId> dir', () => {
    // characterization: the symlink target (outside the session) is preserved;
    // only the link itself could be removed, never the real dir behind it.
    const outsideTarget = fs.mkdtempSync(path.join(require('os').tmpdir(), 'sm-clr-'));
    fs.writeFileSync(path.join(outsideTarget, 'keep.txt'), 'KEEP');
    const outboxRoot = path.join(sessionDir(TEST_AG, SESSION_ID), 'outbox');
    fs.mkdirSync(outboxRoot, { recursive: true });
    fs.symlinkSync(outsideTarget, path.join(outboxRoot, 'evil'));

    clearOutbox(TEST_AG, SESSION_ID, 'evil');

    expect(fs.existsSync(outsideTarget)).toBe(true);
    expect(fs.existsSync(path.join(outsideTarget, 'keep.txt'))).toBe(true);

    fs.rmSync(outsideTarget, { recursive: true, force: true });
  });
});

// ── resolveSession: owner_key stamping ──

describe('resolveSession owner_key', () => {
  it('resolveSession stamps owner_key from the argument', () => {
    createAgentGroup({ id: TEST_AG, name: 'Test', folder: TEST_AG, agent_provider: null, created_at: now() });
    const { session } = resolveSession(TEST_AG, null, null, 'agent-shared', 'p2');
    expect(session.owner_key).toBe('p2');
    expect(getSession(session.id)?.owner_key).toBe('p2');
  });

  it('resolveSession defaults owner_key to OWNER_PERSON_KEY', () => {
    createAgentGroup({ id: TEST_AG, name: 'Test', folder: TEST_AG, agent_provider: null, created_at: now() });
    const { session } = resolveSession(TEST_AG, null, null, 'agent-shared');
    expect(session.owner_key).toBe(OWNER_PERSON_KEY);
  });

  it('a rotated session inherits the prior session owner_key when no owner is passed', () => {
    createAgentGroup({ id: TEST_AG, name: 'Test', folder: TEST_AG, agent_provider: null, created_at: now() });
    const first = resolveSession(TEST_AG, null, null, 'agent-shared', 'p2').session;
    updateSession(first.id, { status: 'closed' });
    const second = resolveSession(TEST_AG, null, null, 'agent-shared').session; // no owner arg
    expect(second.owner_key).toBe('p2');
  });
});

// ── resolveSession: cross-owner recurring-task migration guard (SECURITY) ──

describe('resolveSession recurring-task migration owner gate', () => {
  // Count live recurring tasks in a session's inbound.db — mirrors the read
  // shape migrateRecurringTasks uses (kind='task', recurrence set, pending/paused).
  function countRecurring(agentGroupId: string, sessionId: string): number {
    const db = openInboundDb(agentGroupId, sessionId);
    try {
      const row = db
        .prepare(
          "SELECT COUNT(*) AS n FROM messages_in WHERE kind = 'task' AND recurrence IS NOT NULL AND status IN ('pending', 'paused')",
        )
        .get() as { n: number };
      return row.n;
    } finally {
      db.close();
    }
  }

  // Seed one live recurring task into a session's inbound.db, using the
  // scheduling module's insert helper (same path the agent's schedule tool uses).
  function seedRecurringTask(agentGroupId: string, sessionId: string) {
    const db = openInboundDb(agentGroupId, sessionId);
    try {
      insertTask(db, {
        id: 'task-seed',
        processAfter: new Date().toISOString(),
        recurrence: '0 9 * * *',
        platformId: null,
        channelType: null,
        threadId: null,
        content: JSON.stringify({ prompt: 'morning brief' }),
      });
    } finally {
      db.close();
    }
  }

  it('does NOT migrate a foreign-owner prior session recurring tasks (security guard)', () => {
    createAgentGroup({ id: TEST_AG, name: 'Test', folder: TEST_AG, agent_provider: null, created_at: now() });

    // Prior session owned by `sergei`, carrying a live recurring task.
    const prior = resolveSession(TEST_AG, null, null, 'agent-shared', 'sergei').session;
    seedRecurringTask(TEST_AG, prior.id);
    expect(countRecurring(TEST_AG, prior.id)).toBe(1); // sanity: seed landed
    updateSession(prior.id, { status: 'closed' });

    // Fresh session for a DIFFERENT owner `p2` (e.g. via a2a, which passes ownerKey).
    const fresh = resolveSession(TEST_AG, null, null, 'agent-shared', 'p2').session;

    expect(fresh.owner_key).toBe('p2');
    // sergei's recurring task must NOT have leaked into p2's session.
    expect(countRecurring(TEST_AG, fresh.id)).toBe(0);
  });

  it('DOES migrate recurring tasks on same-owner rotation (positive control)', () => {
    createAgentGroup({ id: TEST_AG, name: 'Test', folder: TEST_AG, agent_provider: null, created_at: now() });

    // Prior owned by `sergei` with a live recurring task.
    const prior = resolveSession(TEST_AG, null, null, 'agent-shared', 'sergei').session;
    seedRecurringTask(TEST_AG, prior.id);
    expect(countRecurring(TEST_AG, prior.id)).toBe(1);
    updateSession(prior.id, { status: 'closed' });

    // Rotation with NO owner arg → effectiveOwnerKey inherits `sergei`.
    const fresh = resolveSession(TEST_AG, null, null, 'agent-shared').session;

    expect(fresh.owner_key).toBe('sergei');
    // Legit same-owner rotation still carries the recurring task forward.
    expect(countRecurring(TEST_AG, fresh.id)).toBe(1);
  });
});
