import { createHash } from 'node:crypto';

import { getDb } from '../../../db/connection.js';

export function hashToken(rawToken: string): string {
  return createHash('sha256').update(rawToken, 'utf8').digest('hex');
}

export interface IosTokenIdentity {
  platform_id: string;
  person_key: string;
}

/**
 * Insert or re-mint a token for a platform_id. Re-minting (same platform_id,
 * new raw token) replaces the row so the old hash stops resolving. person_key
 * stamps session.owner_key + per-person paths for this device's owner.
 */
export function upsertIosToken(args: {
  rawToken: string;
  platformId: string;
  personKey: string;
  label: string | null;
}): void {
  const db = getDb();
  // One platform_id ↔ one current token: clear any prior row for this
  // platform_id before inserting the new hash. After the DELETE the INSERT
  // is unconditionally safe; the PRIMARY KEY constraint throwing on a
  // hash collision is the correct outcome (SHA-256 collision = impossible).
  db.prepare('DELETE FROM ios_tokens WHERE platform_id = ?').run(args.platformId);
  db.prepare(
    `INSERT INTO ios_tokens (token_hash, platform_id, person_key, label, created_at)
     VALUES (?, ?, ?, ?, ?)`,
  ).run(hashToken(args.rawToken), args.platformId, args.personKey, args.label, new Date().toISOString());
}

/** Resolve a raw bearer token to its identity, or null if unknown. */
export function resolveIosToken(rawToken: string): IosTokenIdentity | null {
  const row = getDb()
    .prepare('SELECT platform_id, person_key FROM ios_tokens WHERE token_hash = ?')
    .get(hashToken(rawToken)) as IosTokenIdentity | undefined;
  return row ?? null;
}

/**
 * Resolve a platform_id to the person_key that owns that device, or null if no
 * token has been minted for it. Used at bootstrap to stamp eager-created
 * sessions with their real owner (an ios-app-v2 mg ↔ one person), so a second
 * person's sessions never fall back to OWNER_PERSON_KEY in buildMounts.
 */
export function personKeyForPlatform(platformId: string): string | null {
  const row = getDb().prepare('SELECT person_key FROM ios_tokens WHERE platform_id = ?').get(platformId) as
    | { person_key: string }
    | undefined;
  return row?.person_key ?? null;
}
