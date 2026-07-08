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
import { writeMessageOut } from '../db/messages-out.js';
import { getSessionRouting } from '../db/session-routing.js';
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
function writeWorkoutOut(content: Record<string, unknown>): void {
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

export const workoutStartPlan: McpToolDefinition = {
  tool: {
    name: 'workout.start_plan',
    description:
      'Send the full workout plan to the iOS app. App pre-caches everything (plan + image manifest) so the session runs offline. Call exactly once at the start of a workout.',
    inputSchema: {
      type: 'object' as const,
      properties: {
        workout_id: { type: 'string', description: 'Stable id for this workout (UUID or yyyy-mm-dd slug).' },
        plan_json: { type: 'object', description: 'Full plan tree: exercises, sets, reps, target RPE, rest seconds.' },
        image_manifest: {
          type: 'array',
          description:
            'Optional image references per exercise; iOS prefetches by slug+sha256. Omit (or pass []) when you have no images — the card renders with placeholders.',
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
      required: ['workout_id', 'plan_json'],
    },
  },
  async handler(args) {
    const g = guard();
    if (!g.ok) return g.res;
    writeWorkoutOut({
      type: 'workout_plan',
      payload: {
        workout_id: args.workout_id,
        plan_json: args.plan_json,
        image_manifest: args.image_manifest ?? [],
      },
    });
    return ok(`workout_plan sent for ${args.workout_id}`);
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
    writeWorkoutOut({
      type: 'exercise_swap_options',
      payload: {
        workout_id: args.workout_id,
        from_exercise_slug: args.from_exercise_slug,
        options: args.options,
      },
    });
    return ok(`swap options sent (${(args.options as unknown[]).length})`);
  },
};
