/**
 * Gather `LintInput` from disk and the central DB. The IO half of the lint —
 * kept apart from `a2a-lint.ts` so the rules stay pure and fixture-testable.
 *
 * `groups/` is gitignored and installation-specific, so the repo can test the
 * lint RULES against fixtures but can never assert anything about a
 * particular install's own agents. `gatherLintInput` is that live assertion —
 * what `ncl groups lint` runs against a real install.
 */
import fs from 'fs';
import path from 'path';

import { readAgentDescriptor, type AgentDescriptor } from '../../agent-registry.js';
import { getAllAgentGroups } from '../../db/agent-groups.js';
import { getDb, hasTable } from '../../db/connection.js';
import { getDestinations } from './db/agent-destinations.js';
import type { A2aSend, FragmentRef, LintInput, RejectedField } from './a2a-lint.js';

const SEND_RE = /<message\s+to="([a-zA-Z0-9_-]+)"\s+kind="([a-zA-Z0-9_-]+)"/g;
const FRAGMENT_RE = /profiles\/([a-zA-Z0-9_-]+)\.md/g;
/**
 * Brace-expansion shorthand for several fragments at once, as real skills write
 * it: `profiles/{greg,gordon,payne,scrooge}.md` (jarvis/CLAUDE.md). FRAGMENT_RE
 * matches none of those four — it wants a single identifier — so without this
 * the reads are invisible and a typo'd name inside the list never raises
 * `unknown_fragment_ref`. Matching the brace form literally can only ever match
 * a real brace expansion, so this widens coverage without risking prose.
 */
const FRAGMENT_BRACE_RE = /profiles\/\{([a-zA-Z0-9_,-]+)\}\.md/g;

/**
 * Fields `readAgentDescriptor` salvages or drops independently (see its doc
 * comment) — the set this layer must diff raw-vs-parsed to tell a REJECTED
 * field apart from one that was simply never written.
 */
const REJECTABLE_FIELDS = ['role', 'aka', 'a2a_in', 'publishes'] as const;

/** Every markdown file an agent's prompt can pull in: its CLAUDE.md and its skills. */
function agentDocs(agentsDir: string, folder: string): string[] {
  const out: string[] = [];
  const claude = path.join(agentsDir, folder, 'CLAUDE.md');
  if (fs.existsSync(claude)) out.push(claude);

  const skills = path.join(agentsDir, folder, 'skills');
  let entries: fs.Dirent[] = [];
  try {
    entries = fs.readdirSync(skills, { withFileTypes: true, recursive: true });
  } catch {
    return out; // no skills/ dir for this agent yet
  }
  for (const e of entries) {
    if (!e.isFile() || !e.name.endsWith('.md')) continue;
    // `recursive: true` gives every entry a `parentPath` — the directory that
    // directly contains it, however deep. `path` is the pre-20.12 alias for
    // the same value (removed on newer Node); falling back to it keeps this
    // working on the oldest Node this project supports (engines: >=20).
    const parent = e.parentPath ?? e.path;
    out.push(path.join(parent, e.name));
  }
  return out;
}

/** `where`, relative to agentsDir, with forward slashes regardless of platform. */
function rel(agentsDir: string, p: string): string {
  return path.relative(agentsDir, p).split(path.sep).join('/');
}

/**
 * Every `<message to="X" kind="Y">` authored in an agent's own CLAUDE.md or
 * skills. The dedup key includes the file, not just (from, to, kind): the
 * same kind sent to the same target from two different skills (real example —
 * payne sends `workout_summary` to greg from both `workout-mode` and
 * `chat-log`) is two separate places an operator would need to look, so it
 * stays two entries. A literal repeat of the same tag within one file
 * collapses to one, since there is nothing more specific than the file to
 * point at.
 */
export function scanSends(agentsDir: string, folders: string[]): A2aSend[] {
  const out: A2aSend[] = [];
  const seen = new Set<string>();
  for (const folder of folders) {
    for (const file of agentDocs(agentsDir, folder)) {
      const body = fs.readFileSync(file, 'utf8');
      for (const m of body.matchAll(SEND_RE)) {
        const key = `${folder}|${m[1]}|${m[2]}|${file}`;
        if (seen.has(key)) continue;
        seen.add(key);
        out.push({ from: folder, to: m[1], kind: m[2], where: rel(agentsDir, file) });
      }
    }
  }
  return out.sort((a, b) => a.where.localeCompare(b.where) || a.kind.localeCompare(b.kind));
}

/**
 * Every `profiles/<target>.md` reference in an agent's own CLAUDE.md or
 * skills — a pull-channel read of a peer's published fragment. Both the single
 * form and the brace-expansion form (see FRAGMENT_BRACE_RE) count. An agent's
 * reference to its OWN fragment is its publish target, not a peer read, so
 * it is excluded here rather than reported as a self-loop — in either form.
 */
export function scanFragmentRefs(agentsDir: string, folders: string[]): FragmentRef[] {
  const out: FragmentRef[] = [];
  const seen = new Set<string>();
  for (const folder of folders) {
    for (const file of agentDocs(agentsDir, folder)) {
      const body = fs.readFileSync(file, 'utf8');
      const targets: string[] = [];
      for (const m of body.matchAll(FRAGMENT_RE)) targets.push(m[1]);
      for (const m of body.matchAll(FRAGMENT_BRACE_RE)) targets.push(...m[1].split(','));
      for (const target of targets) {
        // A trailing/doubled comma yields an empty name — not a fragment ref.
        if (!target || target === folder) continue;
        const key = `${folder}|${target}|${file}`;
        if (seen.has(key)) continue;
        seen.add(key);
        out.push({ from: folder, target, where: rel(agentsDir, file) });
      }
    }
  }
  return out.sort((a, b) => a.where.localeCompare(b.where) || a.target.localeCompare(b.target));
}

/**
 * Diff the raw `agent.json` against what `readAgentDescriptor` salvaged,
 * field by field, to recover the one bit the reader collapses: REJECTED
 * (present in the file, malformed, dropped) vs ABSENT (never claimed). Both
 * read back as `undefined` from the parsed descriptor, but for `a2a_in`
 * especially they mean opposite things — see `a2a-lint.ts`'s `malformed_descriptor`
 * rule, which is the reason this function exists.
 *
 * Exported standalone (rather than folded into `gatherLintInput`'s loop) because
 * this is the one piece of that function testable without a live DB: it only
 * touches the filesystem, given a descriptor the caller already parsed.
 */
export function rejectedFields(agentsDir: string, folder: string, parsed: AgentDescriptor): RejectedField[] {
  let raw: unknown;
  try {
    raw = JSON.parse(fs.readFileSync(path.join(agentsDir, folder, 'agent.json'), 'utf8'));
  } catch {
    return []; // unreadable/unparseable — readAgentDescriptor already returned null for this case
  }
  if (raw === null || typeof raw !== 'object' || Array.isArray(raw)) return [];
  const rawObj = raw as Record<string, unknown>;

  const out: RejectedField[] = [];
  for (const field of REJECTABLE_FIELDS) {
    if (rawObj[field] !== undefined && parsed[field] === undefined) out.push({ folder, field });
  }
  return out;
}

/**
 * Assemble the full lint input for a live install: descriptors + rejections
 * from disk (`agents/<folder>/agent.json` and its skills), edges from the
 * central DB (`agent_destinations`). Degrades `edges` to `[]` — rather than
 * throwing — when the a2a module's table isn't installed yet, mirroring the
 * `hasTable` guard every other `agent_destinations` call site uses (e.g.
 * `container-runner.ts`'s `spawnContainer`).
 */
export function gatherLintInput(agentsDir: string): LintInput {
  const groups = getAllAgentGroups();
  const byId = new Map(groups.map((g) => [g.id, g.folder]));
  const folders = groups.map((g) => g.folder);

  const descriptors: Record<string, AgentDescriptor | null> = {};
  const rejected: RejectedField[] = [];
  for (const folder of folders) {
    const d = readAgentDescriptor(agentsDir, folder);
    descriptors[folder] = d;
    // A null descriptor (absent or unparseable JSON) has nothing to diff
    // against — readAgentDescriptor already warned about the unparseable case.
    if (d) rejected.push(...rejectedFields(agentsDir, folder, d));
  }

  const edges: Array<{ from: string; to: string }> = [];
  if (hasTable(getDb(), 'agent_destinations')) {
    for (const g of groups) {
      for (const row of getDestinations(g.id)) {
        if (row.target_type !== 'agent') continue;
        const to = byId.get(row.target_id);
        if (to) edges.push({ from: g.folder, to });
      }
    }
  }

  return {
    descriptors,
    sends: scanSends(agentsDir, folders),
    edges,
    fragmentRefs: scanFragmentRefs(agentsDir, folders),
    rejected,
  };
}
