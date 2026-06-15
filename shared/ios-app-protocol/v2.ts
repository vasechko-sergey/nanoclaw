// Canonical iOS-app wire protocol v2.
// Both host adapter (Node) and agent-runner (Bun) import from here.
// Swift mirror lives in ios/JarvisApp/Sources/JarvisApp/Protocol/V2.swift
// and is pinned via shared/ios-app-protocol/fixtures/*.json contract tests.
import { z } from 'zod';

export const PROTOCOL_VERSION = 2 as const;

export const EnvelopeBase = z.object({
  v: z.literal(2),
  kind: z.enum(['data', 'control', 'ack', 'status']),
  type: z.string(),
  id: z.string().uuid(),
  // Nullable: ack, ping, pong, status:* envelopes carry seq=null and do not
  // advance the per-direction cursor. Ordered types (message, context_request,
  // context_response, new_conversation, action_response, feedback) require an
  // integer >= 0.
  seq: z.number().int().nonnegative().nullable(),
  ts: z.string().datetime(),
});
export type EnvelopeBase = z.infer<typeof EnvelopeBase>;

export const InlineContext = z.object({
  location: z.object({
    lat: z.number(),
    lon: z.number(),
    accuracy: z.number().optional(),
  }).optional(),
  timestamp: z.string().datetime(),
  timezone: z.string(),
  locality: z.string().optional(),
});
export type InlineContext = z.infer<typeof InlineContext>;

export const ContextFieldEnum = z.enum([
  'health', 'calendar', 'device', 'next_event', 'recent_locations', 'screen_state', 'reminders', 'focus',
]);
export type ContextField = z.infer<typeof ContextFieldEnum>;

export const Envelopes = {
  Auth: EnvelopeBase.extend({
    kind: z.literal('control'),
    type: z.literal('auth'),
    payload: z.object({
      token: z.string(),
      last_seen_inbound_seq: z.number().int().nonnegative(),
      capabilities: z.array(z.string()),
    }),
  }),
  AuthOk: EnvelopeBase.extend({
    kind: z.literal('control'),
    type: z.literal('auth_ok'),
    payload: z.object({
      last_seen_outbound_seq: z.number().int().nonnegative(),
      server_time: z.string().datetime(),
      commands: z.array(z.object({
        command: z.string(),
        description: z.string(),
      })).optional(),
    }),
  }),
  AuthFail: EnvelopeBase.extend({
    kind: z.literal('control'),
    type: z.literal('auth_fail'),
    payload: z.object({ reason: z.string() }),
  }),
  Message: EnvelopeBase.extend({
    kind: z.literal('data'),
    type: z.literal('message'),
    payload: z.object({
      thread_id: z.string().min(1),
      text: z.string(),
      attachments: z.array(z.object({
        id: z.string().uuid(),
        kind: z.enum(['image', 'file']),
        name: z.string(),
        mime_type: z.string(),
        byte_size: z.number().int().nonnegative(),
        bytes_base64: z.string().optional(),
        remote_id: z.string().optional(),
      })).optional(),
      context: InlineContext.optional(),
      agent_id: z.string().min(1).optional(),
    }),
  }),
  ContextRequest: EnvelopeBase.extend({
    kind: z.literal('control'),
    type: z.literal('context_request'),
    payload: z.object({
      request_id: z.string().uuid(),
      fields: z.array(ContextFieldEnum).min(1),
      params: z.record(z.string(), z.unknown()).optional(),
      agent_id: z.string().min(1).optional(),
    }),
  }),
  ContextResponse: EnvelopeBase.extend({
    kind: z.literal('control'),
    type: z.literal('context_response'),
    payload: z.object({
      request_id: z.string().uuid(),
      data: z.record(z.string(), z.unknown()),
      errors: z.record(z.string(), z.string()).optional(),
      agent_id: z.string().min(1).optional(),
    }),
  }),
  NewConversation: EnvelopeBase.extend({
    kind: z.literal('control'),
    type: z.literal('new_conversation'),
    payload: z.object({
      thread_id: z.string().min(1),
      agent_id: z.string().min(1).optional(),
    }),
  }),
  ActionResponse: EnvelopeBase.extend({
    kind: z.literal('control'),
    type: z.literal('action_response'),
    payload: z.object({ action_id: z.string(), choice: z.string() }),
  }),
  Feedback: EnvelopeBase.extend({
    kind: z.literal('control'),
    type: z.literal('feedback'),
    payload: z.object({
      message_id: z.string().uuid(),
      kind: z.enum(['up', 'down']),
    }),
  }),
  Ack: EnvelopeBase.extend({
    kind: z.literal('ack'),
    type: z.literal('ack'),
    seq: z.null(),
    payload: z.object({
      id: z.string().uuid(),
      seq: z.number().int().nonnegative(),
    }),
  }),
  Ping: EnvelopeBase.extend({
    kind: z.literal('control'),
    type: z.literal('ping'),
    seq: z.null(),
    payload: z.object({ nonce: z.string().min(1) }),
  }),
  Pong: EnvelopeBase.extend({
    kind: z.literal('control'),
    type: z.literal('pong'),
    seq: z.null(),
    payload: z.object({ nonce: z.string().min(1) }),
  }),
  StatusDelivered: EnvelopeBase.extend({
    kind: z.literal('status'),
    type: z.literal('delivered'),
    seq: z.null(),
    payload: z.object({ ids: z.array(z.string().uuid()).min(1) }),
  }),
  StatusRead: EnvelopeBase.extend({
    kind: z.literal('status'),
    type: z.literal('read'),
    seq: z.null(),
    payload: z.object({ ids: z.array(z.string().uuid()).min(1) }),
  }),
  WorkoutStartRequest: EnvelopeBase.extend({
    kind: z.literal('control'),
    type: z.literal('workout_start_request'),
    payload: z.object({
      date: z.string().regex(/^\d{4}-\d{2}-\d{2}$/),
      agent_id: z.string().min(1).optional(),
    }),
  }),
  WorkoutPlan: EnvelopeBase.extend({
    kind: z.literal('control'),
    type: z.literal('workout_plan'),
    payload: z.object({
      workout_id: z.string().min(1),
      plan_json: z.record(z.string(), z.unknown()),
      image_manifest: z.array(z.object({
        slug: z.string().min(1),
        sha256: z.string().min(1),
        url: z.string().optional(),
      })),
      agent_id: z.string().min(1).optional(),
    }),
  }),
  SetLog: EnvelopeBase.extend({
    kind: z.literal('data'),
    type: z.literal('set_log'),
    payload: z.object({
      workout_id: z.string().min(1),
      exercise_slug: z.string().min(1),
      set_idx: z.number().int().nonnegative(),
      reps: z.number().int().nonnegative(),
      weight: z.number().nonnegative(),
      reps_in_reserve: z.number().int().min(0).max(10),
      ts: z.string().datetime(),
      agent_id: z.string().min(1).optional(),
    }),
  }),
  ExerciseDone: EnvelopeBase.extend({
    kind: z.literal('control'),
    type: z.literal('exercise_done'),
    payload: z.object({
      workout_id: z.string().min(1),
      exercise_slug: z.string().min(1),
      comment: z.string().optional(),
      agent_id: z.string().min(1).optional(),
    }),
  }),
  WorkoutComplete: EnvelopeBase.extend({
    kind: z.literal('data'),
    type: z.literal('workout_complete'),
    payload: z.object({
      workout_id: z.string().min(1),
      full_session_json: z.record(z.string(), z.unknown()),
      agent_id: z.string().min(1).optional(),
    }),
  }),
  WorkoutAbort: EnvelopeBase.extend({
    kind: z.literal('control'),
    type: z.literal('workout_abort'),
    payload: z.object({
      workout_id: z.string().min(1),
      reason: z.string().optional(),
      agent_id: z.string().min(1).optional(),
    }),
  }),
  ImageRequest: EnvelopeBase.extend({
    kind: z.literal('control'),
    type: z.literal('image_request'),
    payload: z.object({
      slug: z.string().min(1),
      agent_id: z.string().min(1).optional(),
    }),
  }),
  ImageBlob: EnvelopeBase.extend({
    kind: z.literal('control'),
    type: z.literal('image_blob'),
    payload: z.object({
      slug: z.string().min(1),
      sha256: z.string().min(1),
      base64: z.string().min(1),
      agent_id: z.string().min(1).optional(),
    }),
  }),
  ExerciseSwapRequest: EnvelopeBase.extend({
    kind: z.literal('control'),
    type: z.literal('exercise_swap_request'),
    payload: z.object({
      workout_id: z.string().min(1),
      exercise_slug: z.string().min(1),
      proposed: z.string().optional(),
      agent_id: z.string().min(1).optional(),
    }),
  }),
  ExerciseSwapConfirm: EnvelopeBase.extend({
    kind: z.literal('control'),
    type: z.literal('exercise_swap_confirm'),
    payload: z.object({
      workout_id: z.string().min(1),
      original_slug: z.string().min(1),
      new_slug: z.string().min(1),
      persist: z.boolean().optional(),
      agent_id: z.string().min(1).optional(),
    }),
  }),
  ExerciseSwapOptions: EnvelopeBase.extend({
    kind: z.literal('control'),
    type: z.literal('exercise_swap_options'),
    payload: z.object({
      workout_id: z.string().min(1),
      original_slug: z.string().min(1),
      accepted: z.object({ slug: z.string() }).optional(),
      rejected: z.object({ slug: z.string(), reason: z.string() }).optional(),
      alternatives: z.array(z.object({ slug: z.string(), why: z.string() })),
      agent_id: z.string().min(1).optional(),
    }),
  }),
  ProgramUpdate: EnvelopeBase.extend({
    kind: z.literal('control'),
    type: z.literal('program_update'),
    payload: z.object({
      program_json: z.record(z.string(), z.unknown()),
      agent_id: z.string().min(1).optional(),
    }),
  }),
  CoachMessage: EnvelopeBase.extend({
    kind: z.literal('control'),
    type: z.literal('coach_message'),
    payload: z.object({
      text: z.string().min(1),
      workout_id: z.string().optional(),
      agent_id: z.string().min(1).optional(),
    }),
  }),
  IntroRequest: EnvelopeBase.extend({
    kind: z.literal('control'),
    type: z.literal('intro_request'),
    payload: z.object({
      agent_id: z.string().min(1).optional(),
    }),
  }),
} as const;

// Health upload — POST /ios/health/upload body. Not an envelope (the WS
// transport is for chat messages); the schema lives here because every
// consumer needs the same shape: the iOS HealthSync/HealthHistory producer,
// the server's http-handler ingest, and Greg's analyze.js downstream reader.
// Fields are all camelCase; the date string is local-day "YYYY-MM-DD". Daily
// aggregates only — no per-sample data crosses this boundary.
export const Workout = z.object({
  type: z.string(),
  startISO: z.string(),
  durationMin: z.number().nonnegative(),
  energyKcal: z.number().nonnegative().optional(),
  avgHR: z.number().int().nonnegative().optional(),
  maxHR: z.number().int().nonnegative().optional(),
});
export type Workout = z.infer<typeof Workout>;

export const HealthUploadDay = z.object({
  date: z.string().regex(/^\d{4}-\d{2}-\d{2}$/),
  steps: z.number().int().nonnegative().optional(),
  activeEnergy: z.number().int().nonnegative().optional(),
  exerciseMinutes: z.number().int().nonnegative().optional(),
  heartRate: z.number().int().nonnegative().optional(),
  restingHeartRate: z.number().int().nonnegative().optional(),
  hrv: z.number().int().nonnegative().optional(),
  sleepHours: z.number().nonnegative().optional(),
  // New in 2026-06-05 spec: sick-day + differential support.
  // wristTempDeviation is signed — HealthKit reports as ±°C around the
  // user's own sleeping baseline, so it can legitimately be negative.
  wristTempDeviation: z.number().optional(),
  respiratoryRate: z.number().nonnegative().optional(),
  walkingHeartRateAverage: z.number().int().nonnegative().optional(),
  vo2max: z.number().nonnegative().optional(),
  // New 2026-06-11: sleep phases (split out of sleepHours), sleep onset for
  // circadian regularity, morning HRV (cleaner than whole-day SDNN), nocturnal
  // SpO2 (min catches desaturation). All optional — older rows omit them and
  // analyze.js's series() skips missing values.
  deepMin: z.number().int().nonnegative().optional(),
  remMin: z.number().int().nonnegative().optional(),
  coreMin: z.number().int().nonnegative().optional(),
  awakeMin: z.number().int().nonnegative().optional(),
  sleepOnsetMin: z.number().int().optional(),       // minutes from local midnight; <0 = before midnight
  hrvMorning: z.number().int().nonnegative().optional(),
  spo2Avg: z.number().nonnegative().optional(),
  spo2Min: z.number().nonnegative().optional(),
  // New 2026-06-12: body composition (smart scale). bodyFatPercentage is a
  // percent number (e.g. 18.5), not a 0-1 fraction. All optional — days with
  // no scale measurement omit them.
  bodyMass: z.number().nonnegative().optional(),
  height: z.number().nonnegative().optional(),
  bodyFatPercentage: z.number().nonnegative().optional(),
  leanBodyMass: z.number().nonnegative().optional(),
  workouts: z.array(Workout).optional(),
});
export type HealthUploadDay = z.infer<typeof HealthUploadDay>;

export const HealthUploadBody = z.object({
  // platformId is required when the server has no IOS_HEALTH_HISTORY_DIR
  // override (it picks the wired agent group from the messaging group).
  // In override mode it's just logged.
  platformId: z.string().optional(),
  // Echoed back from /ios/health/requests so the server can clear the
  // serviced request row.
  requestId: z.string().optional(),
  days: z.array(HealthUploadDay),
});
export type HealthUploadBody = z.infer<typeof HealthUploadBody>;

export const AnyEnvelope = z.discriminatedUnion('type', [
  Envelopes.Auth, Envelopes.AuthOk, Envelopes.AuthFail,
  Envelopes.Message, Envelopes.ContextRequest, Envelopes.ContextResponse,
  Envelopes.NewConversation, Envelopes.ActionResponse, Envelopes.Feedback,
  Envelopes.Ack, Envelopes.Ping, Envelopes.Pong,
  Envelopes.StatusDelivered, Envelopes.StatusRead,
  // Workout-mode envelopes (P3.T1)
  Envelopes.WorkoutStartRequest, Envelopes.WorkoutPlan, Envelopes.SetLog,
  Envelopes.ExerciseDone, Envelopes.WorkoutComplete, Envelopes.WorkoutAbort,
  Envelopes.ImageRequest, Envelopes.ImageBlob,
  Envelopes.ExerciseSwapRequest, Envelopes.ExerciseSwapConfirm,
  Envelopes.ExerciseSwapOptions, Envelopes.ProgramUpdate,
  Envelopes.CoachMessage, Envelopes.IntroRequest,
]);
export type AnyEnvelope = z.infer<typeof AnyEnvelope>;
