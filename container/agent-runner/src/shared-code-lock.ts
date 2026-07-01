import * as fs from 'fs';
import * as path from 'path';

// ── Shared-code write lock ──
//
// Under the shared-code mount model (see host src/container-runner.ts buildMounts),
// an agent's skills/ and scripts/ are ONE source bind-mounted RW into every one of
// its per-session containers. Two concurrent sessions of the same agent (jarvis runs
// Telegram + iOS + headless at once) editing the SAME file would lose an update or
// interleave a half-written file. The user's decision was to SERIALIZE these writes.
//
// The containers are separate processes, so the lock must be a FILESYSTEM lock — an
// in-process mutex wouldn't be visible across containers. We use an advisory lockfile
// at the ROOT of each mounted tree (skills/.write.lock, scripts/.write.lock) so every
// container contends on the same inode. Only the agent-runner writes shared code and
// every write goes through the SDK PreToolUse/PostToolUse hooks, so advisory locking
// among these cooperating writers is sufficient.
//
// A crashed holder (SIGKILL mid-write) would otherwise leave a lock forever, so a
// lock older than STALE_MS is stolen. Acquisition is fail-open: if it can't lock
// (tree missing, or contention past GIVEUP_MS) it returns false and the caller
// proceeds unlocked — a rare lost update is better than hanging the agent.

const DEFAULT_ROOTS = ['/workspace/agent/skills', '/workspace/agent/scripts'];
const WRITE_TOOLS = new Set(['Write', 'Edit', 'NotebookEdit']);
const LOCK_FILE = '.write.lock';

const STALE_MS = 20_000; // a live text-file write finishes in ms; older ⇒ crashed holder
const GIVEUP_MS = 30_000; // safety valve: never block a tool call longer than this
const RETRY_MS = 25;

export interface LockDeps {
  now: () => number;
  sleep: (ms: number) => Promise<void>;
}
const defaultDeps: LockDeps = {
  now: () => Date.now(),
  sleep: (ms) => new Promise((r) => setTimeout(r, ms)),
};

/**
 * The lockfile a tool call must hold, or null if the call doesn't write shared code.
 * Non-write tools, and writes outside the shared trees, take no lock.
 */
export function lockTargetFor(
  toolName: string,
  toolInput: Record<string, unknown> | undefined,
  cwd = '/workspace/agent',
  roots = DEFAULT_ROOTS,
): string | null {
  if (!WRITE_TOOLS.has(toolName)) return null;
  const raw = toolInput?.file_path ?? toolInput?.notebook_path;
  if (typeof raw !== 'string' || raw.length === 0) return null;
  const abs = path.resolve(cwd, raw);
  for (const root of roots) {
    const r = path.resolve(root);
    if (abs === r || abs.startsWith(r + path.sep)) return path.join(r, LOCK_FILE);
  }
  return null;
}

let stealSeq = 0;

/** Acquire the lock (blocking with stale-steal). Returns false = fail-open, proceed unlocked. */
export async function acquireCodeLock(lockPath: string, deps: LockDeps = defaultDeps): Promise<boolean> {
  const start = deps.now();
  for (;;) {
    try {
      const fd = fs.openSync(lockPath, 'wx'); // atomic exclusive create = the lock
      fs.writeSync(fd, `${process.pid}:${deps.now()}`);
      fs.closeSync(fd);
      return true;
    } catch (err) {
      if ((err as NodeJS.ErrnoException).code !== 'EEXIST') return false; // tree missing/perm ⇒ fail-open
    }
    // Held. Steal it if the holder looks dead (lock older than STALE_MS).
    let mtimeMs = 0;
    try {
      mtimeMs = fs.statSync(lockPath).mtimeMs;
    } catch {
      continue; // vanished between open and stat ⇒ retry acquire immediately
    }
    if (deps.now() - mtimeMs > STALE_MS) {
      // Atomic steal: rename the stale file away. Two racers both rename the same
      // src; only the first succeeds (the loser's src is already gone) — so exactly
      // one steals. Then loop back to re-create it fresh.
      const tmp = `${lockPath}.stale.${process.pid}.${++stealSeq}`;
      try {
        fs.renameSync(lockPath, tmp);
        fs.unlinkSync(tmp);
      } catch {
        /* lost the steal race — just retry */
      }
      continue;
    }
    if (deps.now() - start > GIVEUP_MS) return false; // fail-open safety valve
    await deps.sleep(RETRY_MS);
  }
}

/** Release a lock we hold. Safe to call when the lock is already gone. */
export function releaseCodeLock(lockPath: string): void {
  try {
    fs.unlinkSync(lockPath);
  } catch {
    /* already released/stolen */
  }
}

// ── SDK-hook glue ──
//
// The Claude Agent SDK fires PreToolUse then PostToolUse (or PostToolUseFailure)
// for every tool, serially within a session. We hold the lock across that pair as
// a single module slot: acquire in Pre, release in Post. One poll-loop per container
// ⇒ one slot is enough.

let heldCodeLock: string | null = null;

/**
 * PreToolUse: if this call writes shared code, acquire its tree lock (blocking).
 * Returns true = locked, false = fail-open (proceed unlocked), null = not shared code.
 */
export async function lockForToolCall(
  toolName: string,
  toolInput: Record<string, unknown> | undefined,
  cwd?: string,
  roots?: string[],
  deps?: LockDeps,
): Promise<boolean | null> {
  const target = lockTargetFor(toolName, toolInput, cwd, roots);
  if (!target) return null;
  if (heldCodeLock) releaseCodeLock(heldCodeLock); // never leak a prior unpaired lock
  const ok = await acquireCodeLock(target, deps);
  heldCodeLock = ok ? target : null;
  return ok;
}

/** PostToolUse / PostToolUseFailure: release whatever lockForToolCall took. */
export function unlockAfterToolCall(): void {
  if (heldCodeLock) {
    releaseCodeLock(heldCodeLock);
    heldCodeLock = null;
  }
}
