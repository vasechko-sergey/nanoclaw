/**
 * Workout MCP tools for Payne.
 *
 * Each tool writes a structured outbound row whose JSON body carries the
 * envelope type expected by the iOS-app v2 workout-bridge:
 *   - workout.start_plan → type 'workout_plan'
 *   - workout.coach      → type 'coach_message'
 *   - workout.swap       → type 'exercise_swap_options'
 *
 * The workout-bridge on the host parses content.type and forwards as the
 * matching iOS envelope.
 *
 * Guard: tools are inert unless AGENT_GROUP_ID === 'payne'. The container
 * mounts all MCP-tool plugins for every agent; the guard prevents Jarvis
 * (or any other agent) from accidentally pushing workout UI events.
 */
import { loadConfig } from '../config.js';
import { buildImageManifest, DEFAULT_EXERCISES_DIR, type ImageManifestEntry } from '../exercise-images.js';
import { buildPlan, defaultPlanPaths, readinessFor, sendWorkoutPlan, writeWorkoutOut } from '../workout-plan.js';
import type { McpToolDefinition } from './types.js';

function ok(text: string) {
  return { content: [{ type: 'text' as const, text }] };
}
function err(text: string) {
  return { content: [{ type: 'text' as const, text: `Error: ${text}` }], isError: true };
}

function guard(): { ok: true } | { ok: false; res: ReturnType<typeof err> } {
  // container.json (loadConfig) is the source of truth; env is a test fallback.
  // See the gate comment in mcp-tools/index.ts.
  if ((loadConfig().agentGroupId || process.env.AGENT_GROUP_ID) !== 'payne') {
    return { ok: false, res: err('workout.* tools are only enabled for the payne agent') };
  }
  return { ok: true };
}

/** The owner's calendar date (YYYY-MM-DD) in OWNER_TZ — what Greg's signal is dated by. */
function ownerToday(): string {
  const tz = process.env.OWNER_TZ || undefined;
  try {
    return new Intl.DateTimeFormat('en-CA', { timeZone: tz, year: 'numeric', month: '2-digit', day: '2-digit' }).format(new Date());
  } catch {
    return new Date().toISOString().slice(0, 10);
  }
}

/**
 * Build today's plan with the agent's own scripts/build-plan.js and send it.
 * Greg's readiness for the day is read from the host-kept signal file unless
 * the model states one (`health`). Every outcome that is not a card is an
 * error the model must act on — rest day, closed mesocycle, broken builder.
 */
function buildAndSend(workoutId: string, day: string | undefined, healthArg: unknown) {
  const paths = defaultPlanPaths();
  let health: 'yellow' | null;
  if (healthArg === 'yellow' || healthArg === 'green') {
    health = healthArg === 'yellow' ? 'yellow' : null;
  } else {
    const date = /^\d{4}-\d{2}-\d{2}$/.test(workoutId) ? workoutId : ownerToday();
    const r = readinessFor(date, paths.healthSignalPath);
    if (r.kind === 'rest') {
      return err(
        `no plan sent: Greg's signal for ${date} is red. Tell the user today is rest or light cardio and wait for their confirmation — do not send a plan.`,
      );
    }
    if (r.kind === 'unknown') {
      return err(
        `no plan sent: can't read Greg's readiness (${r.detail}). Decide the day's readiness yourself, then call again with health: 'yellow' (lighter) or health: 'green' (as planned).`,
      );
    }
    health = r.health;
  }
  const built = buildPlan(workoutId, health, paths.agentDir, { day });
  if (!built.ok && built.reason === 'cycle_complete') {
    return err(
      `no plan sent: the mesocycle is complete (${built.detail}). Tell the user and build the next program — never invent a day from the tail.`,
    );
  }
  if (!built.ok) return err(`no plan sent: build-plan.js failed — ${built.detail}`);
  const { images } = sendWorkoutPlan(workoutId, built.plan, paths);
  const p = built.plan;
  const n = Array.isArray(p.exercises) ? p.exercises.length : 0;
  return ok(
    `workout_plan sent for ${workoutId}: ${p.day_name}, week ${p.week} (${p.week_label})${health ? ', lighter (yellow)' : ''}, ${n} exercises` +
      `${images ? `, ${images} images` : ''}. The card is in the chat — don't send it again or restate it.`,
  );
}

export const workoutStartPlan: McpToolDefinition = {
  tool: {
    name: 'workout.start_plan',
    description:
      "Send today's workout plan to the iOS app as a card. Pass only workout_id (the owner's date, YYYY-MM-DD): the tool builds the plan with scripts/build-plan.js and applies Greg's readiness signal itself — never build or re-type plan_json. " +
      "Optional: day (split key, e.g. upper_a) to force a day; health ('yellow' lighter / 'green' as planned) only to override Greg's signal. " +
      'An error means no card was sent — rest day, closed mesocycle, or a broken builder; tell the user. plan_json is only for a plan you were explicitly asked to compose by hand.',
    inputSchema: {
      type: 'object' as const,
      properties: {
        workout_id: { type: 'string', description: "The owner's date, YYYY-MM-DD (stable id for this workout)." },
        day: { type: 'string', description: 'Optional split day key (upper_a / lower_a / upper_b / lower_b). Default: the next day in the cycle.' },
        health: { type: 'string', enum: ['yellow', 'green'], description: "Optional override of Greg's signal for the day." },
        plan_json: { type: 'object', description: 'Only for a hand-composed plan. Omit to have the tool build it.' },
        image_manifest: {
          type: 'array',
          description:
            'Optional image references per exercise; iOS prefetches by slug+sha256. Omit — the tool derives it from the exercise images.',
          items: {
            type: 'object',
            properties: {
              slug: { type: 'string' },
              sha256: { type: 'string' },
              url: { type: 'string' },
            },
            required: ['slug', 'sha256'],
          },
        },
      },
      required: ['workout_id'],
    },
  },
  async handler(args) {
    const g = guard();
    if (!g.ok) return g.res;
    const workoutId = String(args.workout_id ?? '');
    if (!workoutId) return err('workout_id is required');
    if (args.plan_json === undefined || args.plan_json === null) {
      return buildAndSend(workoutId, typeof args.day === 'string' ? args.day : undefined, args.health);
    }
    // A hand-composed plan: normalized onto the wire vocab, manifest derived
    // when none is supplied (see sendWorkoutPlan).
    const manifest = Array.isArray(args.image_manifest) ? (args.image_manifest as ImageManifestEntry[]) : [];
    const { images } = sendWorkoutPlan(workoutId, args.plan_json, { ...defaultPlanPaths(), manifest });
    return ok(`workout_plan sent for ${workoutId}${images ? ` (auto-derived ${images} images)` : ''}`);
  },
};

export const workoutCoach: McpToolDefinition = {
  tool: {
    name: 'workout.coach',
    description:
      'Short in-workout message. Goes to the workout UI, not the chat scroll. Use sparingly: PR, missed-set pattern, fatigue cue. If replying to a deviating set, include set_ref so iOS anchors the reply on that set chip. Default to silence.',
    inputSchema: {
      type: 'object' as const,
      properties: {
        workout_id: { type: 'string' },
        text: { type: 'string', description: 'One or two sentences, plain language.' },
        set_ref: {
          type: 'object',
          description: 'Anchor this coach reply to a specific logged set. Include when replying to a deviation.',
          properties: {
            exercise_slug: { type: 'string' },
            set_idx: { type: 'number' },
          },
          required: ['exercise_slug', 'set_idx'],
        },
      },
      required: ['workout_id', 'text'],
    },
  },
  async handler(args) {
    const g = guard();
    if (!g.ok) return g.res;
    const payload: Record<string, unknown> = { workout_id: args.workout_id, text: args.text };
    // Fix K: strict validation. Both `exercise_slug` (non-empty string) and
    // `set_idx` (non-negative integer) are REQUIRED whenever set_ref is
    // present — iOS's V2.CoachMessage.SetRef is non-optional on both fields,
    // so a partial ref (e.g. `{exercise_slug: "x"}` from a lazy LLM output)
    // fails Codable synthesis on the WHOLE envelope, silently dropping the
    // coach text too. Drop the ref instead — the text still lands via the
    // 4-sec top banner / injected chat row.
    const rawRef = args.set_ref as Record<string, unknown> | undefined;
    if (rawRef && typeof rawRef === 'object' && !Array.isArray(rawRef)) {
      const slug = rawRef.exercise_slug;
      const idx = rawRef.set_idx;
      const slugOk = typeof slug === 'string' && slug.length > 0;
      const idxOk = typeof idx === 'number' && Number.isInteger(idx) && idx >= 0;
      if (slugOk && idxOk) {
        payload.set_ref = { exercise_slug: slug, set_idx: idx };
      }
    }
    writeWorkoutOut({ type: 'coach_message', payload });
    return ok('coach_message sent');
  },
};

export const workoutSwap: McpToolDefinition = {
  tool: {
    name: 'workout.swap',
    description:
      'Offer the user 1-3 swap options for an exercise mid-workout. User picks one in the iOS swap sheet.',
    inputSchema: {
      type: 'object' as const,
      properties: {
        workout_id: { type: 'string' },
        from_exercise_slug: { type: 'string' },
        options: {
          type: 'array',
          items: {
            type: 'object',
            properties: {
              slug: { type: 'string' },
              reason: { type: 'string' },
              name_ru: {
                type: 'string',
                description:
                  "Russian display name (exercises/<slug>.json name_ru). Without it iOS shows the transliterated slug in the sheet AND keeps the OLD name after the swap.",
              },
            },
            required: ['slug', 'reason'],
          },
          minItems: 1,
          maxItems: 3,
        },
      },
      required: ['workout_id', 'from_exercise_slug', 'options'],
    },
  },
  async handler(args) {
    const g = guard();
    if (!g.ok) return g.res;
    // Map the ergonomic tool input (from_exercise_slug + options[{slug,reason}])
    // onto the canonical wire shape the iOS Codable requires: original_slug +
    // alternatives[{slug,why}] (shared/ios-app-protocol/v2.ts ExerciseSwapOptions).
    // Passing the input field names through verbatim made iOS drop the whole
    // envelope on decode (required original_slug/alternatives missing), so the
    // swap sheet never received its options.
    const options = Array.isArray(args.options)
      ? (args.options as Array<{ slug: string; reason: string; name_ru?: string }>)
      : [];
    // Carry the image sha alongside each alternative so iOS can add a manifest
    // entry when the user accepts one. Derived here from the same on-disk assets
    // serveImageRequests serves, so the sha matches the cached blob and the
    // runner resolves a real image instead of a placeholder. Payne never has to
    // compute it.
    const exercisesDir = process.env.WORKOUT_EXERCISES_DIR || DEFAULT_EXERCISES_DIR;
    const shaBySlug = new Map(
      buildImageManifest(
        options.map((o) => o.slug),
        exercisesDir,
      ).map((e) => [e.slug, e.sha256]),
    );
    writeWorkoutOut({
      type: 'exercise_swap_options',
      payload: {
        workout_id: args.workout_id,
        original_slug: args.from_exercise_slug,
        alternatives: options.map((o) => ({
          slug: o.slug,
          why: o.reason,
          ...(o.name_ru ? { name_ru: o.name_ru } : {}),
          ...(shaBySlug.has(o.slug) ? { sha256: shaBySlug.get(o.slug) } : {}),
        })),
      },
    });
    return ok(`swap options sent (${options.length})`);
  },
};
