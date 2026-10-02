/**
 * Today's workout plan, built and shipped without the model.
 *
 * Payne's plan is deterministic: scripts/build-plan.js picks the split day from
 * the training log, the weights from the trend, the sets from the week. The
 * model only ever ran that script and re-typed its output into the
 * workout.start_plan tool — six model round trips and ~1100 output tokens of
 * transcription per plan. Two callers now share this module instead:
 *   - poll-loop `serveWorkoutStartRequests` — the iOS "plan for today" button
 *     (`workout_start_request`) is answered by the runner itself, no model.
 *   - mcp-tools/workout.ts `workout.start_plan` — a plan asked for in chat;
 *     the tool builds it, the model passes only the workout id.
 *
 * Greg's readiness comes from /workspace/shared/health/signal.json, which the
 * host rewrites on every `health_signal` Greg sends (src/modules/agent-to-agent/
 * health-signal-file.ts) — structured and dated, unlike the conversation
 * context, which a context reset wipes.
 */
import { spawnSync } from 'node:child_process';
import { existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

import { writeMessageOut } from './db/messages-out.js';
import { getSessionRouting } from './db/session-routing.js';
import { buildImageManifest, DEFAULT_EXERCISES_DIR, type ImageManifestEntry } from './exercise-images.js';

export const DEFAULT_AGENT_DIR = '/workspace/agent';
export const DEFAULT_HEALTH_SIGNAL_PATH = '/workspace/shared/health/signal.json';
/** The builder's own band edge: readiness under 70 → `--health yellow` (scripts/build-plan.js HELP). */
const YELLOW_BELOW_READINESS = 70;
const BUILD_TIMEOUT_MS = 30_000;

export interface PlanPaths {
  /** cwd for the builder (its paths are relative); plans/ is kept here. */
  agentDir: string;
  healthSignalPath: string;
  exercisesDir: string;
}

/** Production paths; env overrides are test seams for the MCP tool (a separate process). */
export function defaultPlanPaths(): PlanPaths {
  return {
    agentDir: process.env.WORKOUT_AGENT_DIR || DEFAULT_AGENT_DIR,
    healthSignalPath: process.env.WORKOUT_HEALTH_SIGNAL || DEFAULT_HEALTH_SIGNAL_PATH,
    exercisesDir: process.env.WORKOUT_EXERCISES_DIR || DEFAULT_EXERCISES_DIR,
  };
}

export type Readiness = { kind: 'ok'; health: 'yellow' | null } | { kind: 'rest' } | { kind: 'unknown'; detail: string };

/**
 * What Greg's latest signal means for a workout on `date` (YYYY-MM-DD).
 * No file, or a signal about another day, is "nothing today" — Greg skips
 * green days. An unreadable or malformed file is `unknown`, never a silent
 * green: the caller hands that case to the model.
 */
export function readinessFor(date: string, signalPath: string): Readiness {
  if (!existsSync(signalPath)) return { kind: 'ok', health: null };
  let signal: { date?: unknown; level?: unknown; readiness?: unknown };
  try {
    signal = JSON.parse(readFileSync(signalPath, 'utf8'));
  } catch (err) {
    return { kind: 'unknown', detail: `unreadable ${signalPath}: ${err instanceof Error ? err.message : String(err)}` };
  }
  if (!signal || typeof signal !== 'object') return { kind: 'unknown', detail: `${signalPath} is not an object` };
  if (signal.date !== date) return { kind: 'ok', health: null };
  if (signal.level === 'red') return { kind: 'rest' };
  if (signal.level !== 'green' && signal.level !== 'yellow') {
    return { kind: 'unknown', detail: `level ${JSON.stringify(signal.level)} in ${signalPath}` };
  }
  const low = typeof signal.readiness === 'number' && signal.readiness < YELLOW_BELOW_READINESS;
  return { kind: 'ok', health: signal.level === 'yellow' || low ? 'yellow' : null };
}

export type PlanBuild =
  | { ok: true; plan: Record<string, unknown> }
  | { ok: false; reason: 'cycle_complete' | 'failed'; detail: string };

/**
 * Run the agent's scripts/build-plan.js exactly as the workout-mode skill told
 * the model to: from the agent dir, `--workout-id <date>`, plus `--day` /
 * `--health yellow` when given. Never throws.
 */
export function buildPlan(
  workoutId: string,
  health: 'yellow' | null,
  agentDir: string,
  opts: { day?: string; timeoutMs?: number } = {},
): PlanBuild {
  const script = join(agentDir, 'scripts', 'build-plan.js');
  if (!existsSync(script)) return { ok: false, reason: 'failed', detail: `no ${script}` };
  const args = [script, '--workout-id', workoutId];
  if (opts.day) args.push('--day', opts.day);
  if (health) args.push('--health', health);
  const run = spawnSync(process.execPath, args, {
    cwd: agentDir,
    encoding: 'utf8',
    timeout: opts.timeoutMs ?? BUILD_TIMEOUT_MS,
  });
  if (run.error || run.status !== 0) {
    const why = run.error ? run.error.message : `exit ${run.status}`;
    return { ok: false, reason: 'failed', detail: `${why}: ${(run.stderr ?? '').trim().slice(-400)}` };
  }
  let out: Record<string, unknown>;
  try {
    out = JSON.parse(run.stdout);
  } catch {
    return { ok: false, reason: 'failed', detail: `not JSON: ${run.stdout.trim().slice(0, 200)}` };
  }
  if (out && out.cycle_complete === true) {
    return { ok: false, reason: 'cycle_complete', detail: JSON.stringify(out) };
  }
  if (!out || typeof out !== 'object' || !Array.isArray(out.exercises)) {
    return { ok: false, reason: 'failed', detail: `no exercises in: ${run.stdout.trim().slice(0, 200)}` };
  }
  return { ok: true, plan: out };
}

/**
 * Nullish pick: first defined, non-null value among the candidates. Uses `??`
 * semantics so a legitimate 0 (target_rir: 0 = to-failure) or "" survives —
 * a `||` fallback would silently drop them.
 */
function pick(...vals: unknown[]): unknown {
  for (const v of vals) if (v !== undefined && v !== null) return v;
  return undefined;
}

/**
 * Normalize one plan exercise onto the canonical iOS wire vocab
 * (shared/ios-app-protocol/v2.ts PlanExerciseSchema): slug / name_ru /
 * target_sets / target_reps / reps_in_reserve / rest_seconds / duration_seconds /
 * weight_kg_target / notes.
 *
 * Payne builds plan_json from its INTERNAL program vocab (exercise_slug / name /
 * target_rir / rest_sec / execution_duration_seconds / weight_kg |
 * starting_weight, plus a `sets` array iOS never reads). Left un-mapped, iOS
 * decodes the array length but every renamed field falls to its default: empty
 * slug (identical "" ids collapse the ForEach), blank name, no weight, no rest —
 * "8 упражнений" and a blank card. Accept BOTH vocabs so already-canonical plans
 * (e.g. the historical seq-389 envelope) pass through idempotently.
 */
function normalizeExercise(e: Record<string, unknown>): Record<string, unknown> {
  const out: Record<string, unknown> = {
    slug: pick(e.slug, e.exercise_slug),
    target_sets: e.target_sets ?? null,       // warmup/cardio → null
    target_reps: e.target_reps ?? '',
    reps_in_reserve: pick(e.reps_in_reserve, e.target_rir) ?? null,
    rest_seconds: pick(e.rest_seconds, e.rest_sec) ?? 0,
  };
  const nameRu = pick(e.name_ru, e.name);
  if (nameRu !== undefined) out.name_ru = nameRu;
  const dur = pick(e.duration_seconds, e.execution_duration_seconds);
  if (dur !== undefined) out.duration_seconds = dur;
  const weight = pick(e.weight_kg_target, e.weight_kg, e.starting_weight);
  if (weight !== undefined) out.weight_kg_target = weight;
  if (e.notes !== undefined && e.notes !== null) out.notes = e.notes;
  return out;
}

/**
 * Remap plan_json.exercises[] to the canonical wire vocab, passing plan-level
 * keys (day_name / week / week_label / …) through untouched — those already
 * match the wire. Defensive: a plan without an `exercises` array is returned
 * verbatim rather than throwing.
 */
export function normalizePlanJson(plan: unknown): unknown {
  if (!plan || typeof plan !== 'object' || Array.isArray(plan)) return plan;
  const p = plan as Record<string, unknown>;
  if (!Array.isArray(p.exercises)) return plan;
  return {
    ...p,
    exercises: (p.exercises as unknown[]).map((e) =>
      e && typeof e === 'object' && !Array.isArray(e)
        ? normalizeExercise(e as Record<string, unknown>)
        : e,
    ),
  };
}

/** Canonical slugs from a normalized plan (post-normalizeExercise, so `slug`). */
function planSlugs(plan: unknown): string[] {
  if (!plan || typeof plan !== 'object' || Array.isArray(plan)) return [];
  const ex = (plan as Record<string, unknown>).exercises;
  if (!Array.isArray(ex)) return [];
  return ex
    .map((e) => (e && typeof e === 'object' ? (e as Record<string, unknown>).slug : undefined))
    .filter((s): s is string => typeof s === 'string' && s.length > 0);
}

function generateId(): string {
  return `msg-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
}

/**
 * Write a workout-family control row STAMPED with the current session's channel
 * routing. Without platform_id/channel_type the host delivery poller drops the
 * row ("Message missing routing fields") before it ever reaches the ios-app
 * adapter's workout-bridge — so the plan never leaves the host and no card ever
 * renders. Mirrors how status/scheduling tools route their outbound rows.
 */
export function writeWorkoutOut(content: Record<string, unknown>): void {
  const routing = getSessionRouting();
  writeMessageOut({
    id: generateId(),
    kind: 'control',
    platform_id: routing.platform_id,
    channel_type: routing.channel_type,
    thread_id: routing.thread_id,
    content: JSON.stringify(content),
  });
}

/**
 * Ship `plan` as the iOS `workout_plan` card and keep the sent copy at
 * `<agentDir>/plans/<workoutId>.json`.
 *
 * image_manifest is the ONLY trigger for iOS image prefetch. When none is
 * supplied it is derived from the plan's slugs + the same on-disk assets the
 * image_blob responder (poll-loop serveImageRequests) serves, so the sha256
 * matches and iOS caches/looks-up under one key. A supplied manifest is trusted
 * untouched.
 *
 * The copy matters because a plan the runner sends never passes through the
 * model: without it the agent can't tell the plan was sent, or count planned
 * sets in the end-of-workout summary. Best effort — a failed copy never blocks
 * the card.
 */
export function sendWorkoutPlan(
  workoutId: string,
  plan: unknown,
  opts: { agentDir: string; exercisesDir: string; manifest?: ImageManifestEntry[] },
): { images: number } {
  const planJson = normalizePlanJson(plan);
  const supplied = opts.manifest ?? [];
  const imageManifest = supplied.length > 0 ? supplied : buildImageManifest(planSlugs(planJson), opts.exercisesDir);
  writeWorkoutOut({
    type: 'workout_plan',
    payload: { workout_id: workoutId, plan_json: planJson, image_manifest: imageManifest },
  });
  try {
    const plansDir = join(opts.agentDir, 'plans');
    mkdirSync(plansDir, { recursive: true });
    const target = join(plansDir, `${workoutId.replace(/[^\w.-]/g, '_')}.json`);
    writeFileSync(`${target}.tmp`, JSON.stringify(planJson, null, 2));
    renameSync(`${target}.tmp`, target);
  } catch (err) {
    console.error(`[workout-plan] could not keep plans/${workoutId}.json: ${err instanceof Error ? err.message : String(err)}`);
  }
  return { images: supplied.length > 0 ? 0 : imageManifest.length };
}
