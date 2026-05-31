// Append health-history rows to the per-group raw JSONL file.
//
// Legacy iOS adapter wrote to `groups/<group>/health/raw.jsonl` and the
// analyzer agent read that file (its workspace is mounted at the same path,
// so no additional_mounts plumbing is required). We replicate that on-disk
// contract so the existing analyzer doesn't notice the cutover.
//
// Producer: POST /ios/health/upload.
// Consumer: the analyzer agent inside its container.
import { appendFileSync, mkdirSync } from 'node:fs';
import { dirname, join } from 'node:path';

export interface HealthUploadDay {
  date: string; // 'YYYY-MM-DD'
  steps?: number;
  hr_resting?: number;
  active_energy?: number;
  sleep_hours?: number;
}

export function appendHealthHistory(groupsDir: string, agentGroupFolder: string, days: HealthUploadDay[]): void {
  const path = join(groupsDir, agentGroupFolder, 'health', 'raw.jsonl');
  mkdirSync(dirname(path), { recursive: true });
  const lines = days.map((d) => JSON.stringify({ ...d, ingested_at: Date.now() })).join('\n');
  if (lines.length > 0) appendFileSync(path, lines + '\n');
}
