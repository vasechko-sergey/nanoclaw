import { test, expect, beforeEach, afterEach } from 'bun:test';
import * as fs from 'fs';
import * as os from 'os';
import * as path from 'path';
import { lockTargetFor, acquireCodeLock, releaseCodeLock, lockForToolCall, unlockAfterToolCall } from './shared-code-lock.js';

// A shared-code write must serialize across the per-session containers that
// bind-mount the SAME agents/<folder>/{skills,scripts} RW. The lock lives at the
// root of each mounted tree so every container sees the same inode.

let tmp: string;
let roots: string[];
beforeEach(() => {
  tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'code-lock-'));
  roots = [path.join(tmp, 'skills'), path.join(tmp, 'scripts')];
  for (const r of roots) fs.mkdirSync(r, { recursive: true });
});
afterEach(() => {
  unlockAfterToolCall(); // clear any held module state between tests
  fs.rmSync(tmp, { recursive: true, force: true });
});

// ── lockTargetFor: which tool calls take which lock ──

test('lockTargetFor: Write under skills → the skills tree lock', () => {
  const target = lockTargetFor('Write', { file_path: path.join(roots[0], 'welcome/SKILL.md') }, tmp, roots);
  expect(target).toBe(path.join(roots[0], '.write.lock'));
});

test('lockTargetFor: Edit under scripts → the scripts tree lock', () => {
  const target = lockTargetFor('Edit', { file_path: path.join(roots[1], 'tax-ge.js') }, tmp, roots);
  expect(target).toBe(path.join(roots[1], '.write.lock'));
});

test('lockTargetFor: NotebookEdit uses notebook_path', () => {
  const target = lockTargetFor('NotebookEdit', { notebook_path: path.join(roots[1], 'a.ipynb') }, tmp, roots);
  expect(target).toBe(path.join(roots[1], '.write.lock'));
});

test('lockTargetFor: a relative path resolves against cwd', () => {
  const target = lockTargetFor('Edit', { file_path: 'scripts/tax-ge.js' }, tmp, roots);
  expect(target).toBe(path.join(roots[1], '.write.lock'));
});

test('lockTargetFor: write outside the shared trees (memories) → no lock', () => {
  expect(lockTargetFor('Write', { file_path: path.join(tmp, 'memories/note.md') }, tmp, roots)).toBeNull();
});

test('lockTargetFor: a non-write tool is never locked', () => {
  expect(lockTargetFor('Read', { file_path: path.join(roots[0], 'x') }, tmp, roots)).toBeNull();
  expect(lockTargetFor('Bash', { command: 'echo hi > skills/x' }, tmp, roots)).toBeNull();
});

test('lockTargetFor: a traversal path that escapes the tree does not match it', () => {
  const escape = path.join(roots[0], '../../etc/passwd');
  expect(lockTargetFor('Write', { file_path: escape }, tmp, roots)).toBeNull();
});

test('lockTargetFor: missing file_path → no lock', () => {
  expect(lockTargetFor('Write', {}, tmp, roots)).toBeNull();
  expect(lockTargetFor('Write', undefined, tmp, roots)).toBeNull();
});

// ── acquire / release ──

test('acquireCodeLock on a free path succeeds and creates the lockfile', async () => {
  const lock = path.join(roots[0], '.write.lock');
  expect(await acquireCodeLock(lock)).toBe(true);
  expect(fs.existsSync(lock)).toBe(true);
});

test('releaseCodeLock removes the lockfile; releasing an absent lock does not throw', () => {
  const lock = path.join(roots[0], '.write.lock');
  fs.writeFileSync(lock, 'x');
  releaseCodeLock(lock);
  expect(fs.existsSync(lock)).toBe(false);
  expect(() => releaseCodeLock(lock)).not.toThrow();
});

test('a second acquire blocks while the first holds it, then proceeds after release', async () => {
  const lock = path.join(roots[1], '.write.lock');
  expect(await acquireCodeLock(lock)).toBe(true);

  let bResolved = false;
  const b = acquireCodeLock(lock).then((v) => { bResolved = true; return v; });
  await new Promise((r) => setTimeout(r, 80)); // fresh lock → B keeps retrying, never resolves
  expect(bResolved).toBe(false);

  releaseCodeLock(lock);
  expect(await b).toBe(true); // B gets it once the holder released
});

test('a stale lock (dead holder) is stolen', async () => {
  const lock = path.join(roots[0], '.write.lock');
  fs.writeFileSync(lock, 'dead-holder');
  const old = new Date(Date.now() - 60_000);
  fs.utimesSync(lock, old, old); // older than STALE_MS → a crashed holder
  expect(await acquireCodeLock(lock)).toBe(true);
});

test('acquire fails open (false, no throw) when the tree is missing', async () => {
  const lock = path.join(tmp, 'no-such-tree', '.write.lock');
  expect(await acquireCodeLock(lock)).toBe(false);
});

// ── hook glue: lockForToolCall / unlockAfterToolCall ──

test('lockForToolCall takes the tree lock for a shared-code write; unlock releases it', async () => {
  const ok = await lockForToolCall('Write', { file_path: path.join(roots[0], 'welcome/SKILL.md') }, tmp, roots);
  expect(ok).toBe(true);
  expect(fs.existsSync(path.join(roots[0], '.write.lock'))).toBe(true);
  unlockAfterToolCall();
  expect(fs.existsSync(path.join(roots[0], '.write.lock'))).toBe(false);
});

test('lockForToolCall no-ops (null) for a write outside the shared trees', async () => {
  const ok = await lockForToolCall('Write', { file_path: path.join(tmp, 'memories/n.md') }, tmp, roots);
  expect(ok).toBeNull();
  expect(fs.existsSync(path.join(roots[0], '.write.lock'))).toBe(false);
  expect(() => unlockAfterToolCall()).not.toThrow();
});
