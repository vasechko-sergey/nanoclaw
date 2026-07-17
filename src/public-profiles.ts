/**
 * Project each agent group's self-authored public summary
 * (`groups/<folder>/memories/public.md`) into the shared, read-only profiles
 * directory (`groups/global/profiles/<folder>.md`) that every container
 * mounts at `/workspace/global/profiles/`.
 *
 * "Write your own, host distributes" — same pattern as the session DBs. The
 * agent only ever writes its own workspace; the host fans the fragment out so
 * no agent writes another's file and nothing cross-mount-locks. Copy is
 * hash-gated so an unchanged fragment costs one read, not a write, per sweep.
 *
 * The projection is also where the fragment's declared contract is checked. An
 * agent's `publishes.fields` in agent.json names the body labels its PEERS read;
 * if a declared non-optional label stops being written, this is the only place
 * that can notice. It warns rather than blocks — see missingFields.
 *
 * Returns the number of fragments (re)written this pass.
 */
import crypto from 'crypto';
import fs from 'fs';
import path from 'path';

import { readAgentDescriptor } from './agent-registry.js';
import { isValidGroupFolder } from './group-folder.js';
import { log } from './log.js';

function sha(s: string): string {
  return crypto.createHash('sha256').update(s).digest('hex');
}

/**
 * Fan every person's per-agent public.md into THAT person's global/profiles,
 * iterating the person dirs under `data/user-memory/`. Each person dir has the
 * same shape as `groups/` (<agentFolder>/memories/public.md + global/profiles/),
 * so we reuse projectPublicProfiles per person. Returns total fragments written.
 *
 * Per-person isolation: a person's public.md only ever lands in their OWN
 * global/profiles — projectPublicProfiles is scoped to each person's root.
 */
export function projectAllPublicProfiles(userMemoryBase: string, agentsDir: string): number {
  let persons: fs.Dirent[];
  try {
    persons = fs.readdirSync(userMemoryBase, { withFileTypes: true });
  } catch {
    return 0; // user-memory dir doesn't exist yet (pre-migration) — no-op
  }
  let written = 0;
  for (const p of persons) {
    if (!p.isDirectory()) continue;
    written += projectPublicProfiles(path.join(userMemoryBase, p.name), agentsDir);
  }
  return written;
}

/**
 * Which declared, non-optional body labels are missing from the fragment.
 *
 * Substring match on the label, deliberately loose: the live fragments write it
 * as `**Состав тела:**` while Jarvis writes `**Погода**` with no colon, and the
 * peer reading it is an LLM that matches loosely too. The job here is to notice
 * when a publisher STOPS writing a declared field — not to police formatting.
 */
function missingFields(body: string, agentsDir: string, folder: string): string[] {
  const p = readAgentDescriptor(agentsDir, folder)?.publishes;
  if (!p) return [];
  const optional = new Set(p.optional ?? []);
  return Object.keys(p.fields).filter((label) => !optional.has(label) && !body.includes(label));
}

export function projectPublicProfiles(groupsDir: string, agentsDir: string): number {
  const profilesDir = path.join(groupsDir, 'global', 'profiles');
  let entries: fs.Dirent[];
  try {
    entries = fs.readdirSync(groupsDir, { withFileTypes: true });
  } catch {
    return 0;
  }

  let written = 0;
  for (const entry of entries) {
    if (!entry.isDirectory()) continue;
    const folder = entry.name;
    // isValidGroupFolder rejects the reserved `global` folder and any
    // non-conforming name, so only real agent groups project.
    if (!isValidGroupFolder(folder)) continue;

    const srcPath = path.join(groupsDir, folder, 'memories', 'public.md');
    let src: string;
    try {
      src = fs.readFileSync(srcPath, 'utf8');
    } catch {
      continue; // agent hasn't published yet
    }

    const destPath = path.join(profilesDir, `${folder}.md`);
    let dest: string | null = null;
    try {
      dest = fs.readFileSync(destPath, 'utf8');
    } catch {
      // dest missing → fall through and write
    }
    if (dest !== null && sha(dest) === sha(src)) continue;

    // Behind the hash gate on purpose: this fires only when the fragment
    // actually changed, so a stale one costs one warn, not one per 60s sweep.
    // Warn, never block — a fragment missing a field is degraded, not invalid,
    // and refusing the write would take the dashboard down with it.
    const missing = missingFields(src, agentsDir, folder);
    if (missing.length > 0) {
      log.warn('Fragment is missing declared fields', { folder, missing });
    }

    try {
      fs.mkdirSync(profilesDir, { recursive: true });
      // Write-then-rename: rename is atomic on the same filesystem, so a
      // container reading the read-only mount never sees a half-written
      // fragment. Same idiom as src/channels/telegram-pairing.ts.
      const tmpPath = `${destPath}.tmp`;
      fs.writeFileSync(tmpPath, src);
      fs.renameSync(tmpPath, destPath);
      written++;
    } catch (err) {
      log.warn('Failed to project public profile', { folder, err });
    }
  }
  return written;
}
