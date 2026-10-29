/**
 * Read-only: dump antitrainer.app's whole exercise catalog with each
 * exercise's media links, to see which exercises gained a video since the
 * 2026-06 import (scripts/import-antitrainer.ts).
 *
 * Signs in the way the web app does — a code sent to your email — and keeps
 * the token in memory only: never printed, never written.
 *
 * Usage (interactive — asks for the email and the code):
 *   pnpm exec tsx scripts/antitrainer-catalog.ts <out.json>
 * or with a token you already have (skips the email code):
 *   ANTITRAINER_TOKEN='…' pnpm exec tsx scripts/antitrainer-catalog.ts <out.json>
 *
 * Output: [{ id, name, gif_video, video, rules, warnings }] — gif_video is the
 * inline mp4 the import turns into the exercise gif; video is the trainer's
 * own clip (kinescope), which the import skips.
 */
import fs from 'fs';
import readline from 'readline/promises';

const BASE = 'https://lk.antitrainer.app/api';

const out = process.argv[2];
if (!out) {
  console.error('usage: pnpm exec tsx scripts/antitrainer-catalog.ts <out.json>');
  process.exit(2);
}

async function call<T>(method: 'GET' | 'POST', path: string, token: string | null, body?: unknown): Promise<T> {
  const res = await fetch(`${BASE}/${path}`, {
    method,
    headers: {
      Accept: 'application/json',
      ...(body ? { 'Content-Type': 'application/json' } : {}),
      ...(token ? { Authorization: `Bearer ${token}` } : {}),
    },
    body: body ? JSON.stringify(body) : undefined,
  });
  if (!res.ok) throw new Error(`${method} ${path} → ${res.status}`);
  return res.json() as Promise<T>;
}

/** The token sits under one of a few names depending on the API version. */
function findToken(resp: unknown): string | null {
  const r = resp as Record<string, any>;
  for (const v of [r?.token, r?.access_token, r?.data?.token, r?.data?.access_token, r?.data?.plainTextToken]) {
    if (typeof v === 'string' && v.length > 0) return v;
  }
  return null;
}

async function signIn(): Promise<string> {
  const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
  const email = (await rl.question('Email for antitrainer.app: ')).trim();
  await call('POST', 'auth/request-code', null, { email });
  const code = (await rl.question('Code from the email: ')).trim();
  rl.close();
  const resp = await call<unknown>('POST', 'auth/verify-code', null, { email, code });
  const token = findToken(resp);
  if (!token) {
    // Keys only — the values may hold the token under a name not listed above.
    const r = resp as Record<string, any>;
    console.error('No token in the verify-code answer. Top-level keys:', Object.keys(r ?? {}),
      'data keys:', Object.keys(r?.data ?? {}));
    process.exit(1);
  }
  return token;
}

interface AtExercise {
  id: number;
  name: string;
  video?: { url: string | null } | null;
  gif_video?: { url: string | null } | null;
  rules?: unknown[];
  warnings?: unknown[];
}

async function main() {
  const token = process.env.ANTITRAINER_TOKEN || (await signIn());

  const ids: number[] = [];
  for (let page = 1; ; page++) {
    const resp = await call<{ data: Array<{ id: number }>; meta: { current_page: number; last_page: number } }>(
      'GET', `exercises?page=${page}&per_page=100`, token);
    ids.push(...resp.data.map((e) => e.id));
    if (resp.meta.current_page >= resp.meta.last_page) break;
  }
  console.log(`catalog: ${ids.length} exercises`);

  const rows = [];
  for (const id of ids) {
    try {
      const { data: e } = await call<{ data: AtExercise }>('GET', `exercises/${id}`, token);
      rows.push({
        id: e.id,
        name: e.name,
        gif_video: e.gif_video?.url ?? null,
        video: e.video?.url ?? null,
        rules: e.rules?.length ?? 0,
        warnings: e.warnings?.length ?? 0,
      });
    } catch (err) {
      console.warn(`  ! ${id}: ${(err as Error).message}`);
    }
    await new Promise((r) => setTimeout(r, 150));
  }

  fs.writeFileSync(out, JSON.stringify(rows, null, 2));
  const withGif = rows.filter((r) => r.gif_video).length;
  console.log(`wrote ${rows.length} rows to ${out} — ${withGif} with gif_video`);
}

main().catch((err) => {
  console.error((err as Error).message);
  process.exit(1);
});
