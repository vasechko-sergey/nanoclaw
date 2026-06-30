import fs from 'node:fs';
import path from 'node:path';
import type Database from 'better-sqlite3';
import { log } from '../../log.js';
import { decideSummaryNotify, type SummaryCfg } from './detector.js';
import { getLastNotified, setLastNotified } from './db.js';
import { getSummaryEmitter, type SummaryEmitter } from './emit-registry.js';

export interface RunSummaryNotifyDeps {
  userMemoryBase: string; // data/user-memory
  db: Database.Database; // central db (summary_notify_log)
  nowMs: number;
  cfg: SummaryCfg;
  emit?: SummaryEmitter; // default: the registered emitter (channel-provided)
}

function profileMtimes(personDir: string): number[] {
  const profilesDir = path.join(personDir, 'global', 'profiles');
  let entries: fs.Dirent[];
  try {
    entries = fs.readdirSync(profilesDir, { withFileTypes: true });
  } catch {
    return [];
  }
  const out: number[] = [];
  for (const e of entries) {
    if (!e.isFile() || !e.name.endsWith('.md') || e.name === 'index.md') continue;
    try {
      out.push(fs.statSync(path.join(profilesDir, e.name)).mtimeMs);
    } catch {
      /* ignore */
    }
  }
  return out;
}

export function runSummaryNotify(deps: RunSummaryNotifyDeps): void {
  const emit = deps.emit ?? getSummaryEmitter();
  if (!emit) return; // no channel registered an emitter — nothing to do

  let persons: fs.Dirent[];
  try {
    persons = fs.readdirSync(deps.userMemoryBase, { withFileTypes: true });
  } catch {
    return;
  }

  for (const p of persons) {
    if (!p.isDirectory()) continue;
    const personKey = p.name;
    const cardMtimesMs = profileMtimes(path.join(deps.userMemoryBase, personKey));
    if (cardMtimesMs.length === 0) continue;

    const decision = decideSummaryNotify({
      nowMs: deps.nowMs,
      cardMtimesMs,
      lastNotifiedDate: getLastNotified(deps.db, personKey),
      cfg: deps.cfg,
    });
    if (!decision.fire) continue;

    try {
      emit(personKey, { date: decision.today, count: decision.count });
      setLastNotified(deps.db, personKey, decision.today);
      log.info('Summary-ready notification emitted', { personKey, date: decision.today, count: decision.count });
    } catch (err) {
      log.error('Summary-ready emit failed', { personKey, err });
    }
  }
}
