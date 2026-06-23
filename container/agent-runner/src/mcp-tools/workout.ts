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
    writeMessageOut({
      id: generateId(),
      kind: 'control',
      content: JSON.stringify({
        type: 'workout_plan',
        payload: {
          workout_id: args.workout_id,
          plan_json: args.plan_json,
          image_manifest: args.image_manifest ?? [],
        },
      }),
    });
    return ok(`workout_plan sent for ${args.workout_id}`);
  },
};

export const workoutCoach: McpToolDefinition = {
  tool: {
    name: 'workout.coach',
    description:
      'Short in-workout message. Goes to the workout UI, not the chat scroll. Use sparingly: PR, missed-set pattern, fatigue cue. Default to silence.',
    inputSchema: {
      type: 'object' as const,
      properties: {
        workout_id: { type: 'string' },
        text: { type: 'string', description: 'One or two sentences, plain language.' },
      },
      required: ['workout_id', 'text'],
    },
  },
  async handler(args) {
    const g = guard();
    if (!g.ok) return g.res;
    writeMessageOut({
      id: generateId(),
      kind: 'control',
      content: JSON.stringify({
        type: 'coach_message',
        payload: { workout_id: args.workout_id, text: args.text },
      }),
    });
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
    writeMessageOut({
      id: generateId(),
      kind: 'control',
      content: JSON.stringify({
        type: 'exercise_swap_options',
        payload: {
          workout_id: args.workout_id,
          from_exercise_slug: args.from_exercise_slug,
          options: args.options,
        },
      }),
    });
    return ok(`swap options sent (${(args.options as unknown[]).length})`);
  },
};
