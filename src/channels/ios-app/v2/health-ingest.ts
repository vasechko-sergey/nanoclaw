// Persist health-history rows to the per-group health.db (upsert by date),
// replacing the duplicate-append raw.jsonl. Producer: POST /ios/health/upload.
// Consumer: Greg's analyze.js (reads the same file via bun:sqlite).
import { join } from 'node:path';

import type { HealthUploadDay } from '../../../../shared/ios-app-protocol/index.js';
import { openHealthDb, upsertHealthDays } from './health-db.js';

export function appendHealthHistory(groupsDir: string, agentGroupFolder: string, days: HealthUploadDay[]): void {
  if (days.length === 0) return;
  const db = openHealthDb(join(groupsDir, agentGroupFolder, 'health', 'health.db'));
  try {
    upsertHealthDays(db, days);
  } finally {
    db.close();
  }
}
