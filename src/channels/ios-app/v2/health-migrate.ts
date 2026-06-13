// One-time: fold a duplicate-laden raw.jsonl into health.db. Per date keep the
// row with the highest sleepHours (proxy for "fullest backfill" — partly undoes
// the pre-P1 pre-midnight undercount). Backs up the jsonl, never deletes.
import fs from 'node:fs';
import path from 'node:path';

import { getAllAgentGroups } from '../../../db/agent-groups.js';
import { GROUPS_DIR } from '../../../config.js';
import { log } from '../../../log.js';
import type { HealthUploadDay } from '../../../../shared/ios-app-protocol/index.js';
import { openHealthDb, upsertHealthDays } from './health-db.js';

export function migrateRawJsonlToDb(healthDir: string): void {
  const dbPath = path.join(healthDir, 'health.db');
  const jsonlPath = path.join(healthDir, 'raw.jsonl');
  if (fs.existsSync(dbPath)) return;
  if (!fs.existsSync(jsonlPath)) return;

  const best = new Map<string, HealthUploadDay>();
  for (const line of fs.readFileSync(jsonlPath, 'utf8').split('\n')) {
    const s = line.trim();
    if (!s) continue;
    let r: HealthUploadDay;
    try {
      r = JSON.parse(s) as HealthUploadDay;
    } catch {
      continue;
    }
    if (!r || !r.date) continue;
    const prev = best.get(r.date);
    const better = !prev || (r.sleepHours ?? -1) > (prev.sleepHours ?? -1);
    if (better) best.set(r.date, r);
  }

  const db = openHealthDb(dbPath);
  upsertHealthDays(db, [...best.values()]);
  db.close();
  fs.renameSync(jsonlPath, `${jsonlPath}.migrated-${Date.now()}`);
  log.info('Migrated health raw.jsonl → health.db', { healthDir, dates: best.size });
}

/** Migrate every agent group's health folder. Idempotent. */
export function migrateHealthStores(): void {
  for (const group of getAllAgentGroups()) {
    migrateRawJsonlToDb(path.join(GROUPS_DIR, group.folder, 'health'));
  }
}
