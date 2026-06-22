import { describe, it, expect } from 'vitest';
import { PlanJsonSchema } from './v2.js';

const validPlan = {
  day_name: 'Верх А', week: 1, week_label: 'лёгкая',
  exercises: [
    { slug: 'hodba', name_ru: 'Ходьба', target_sets: null, target_reps: '', reps_in_reserve: null, rest_seconds: 0, duration_seconds: 300, notes: 'разминка' },
    { slug: 'zhim', name_ru: 'Жим', target_sets: 4, target_reps: '5-6', reps_in_reserve: 3, rest_seconds: 180, weight_kg_target: 65 },
  ],
};

describe('PlanJsonSchema', () => {
  it('accepts a canonical plan with a null-warmup', () => {
    const r = PlanJsonSchema.safeParse(validPlan);
    expect(r.success).toBe(true);
  });
  it('rejects an exercise missing slug', () => {
    const bad = { ...validPlan, exercises: [{ target_sets: 3, target_reps: '8', reps_in_reserve: 2, rest_seconds: 90 }] };
    expect(PlanJsonSchema.safeParse(bad).success).toBe(false);
  });
  it('rejects a plan missing week_label', () => {
    const { week_label, ...bad } = validPlan;
    expect(PlanJsonSchema.safeParse(bad).success).toBe(false);
  });
});
