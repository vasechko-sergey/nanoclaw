/**
 * Technique text for an exercise, read from its card
 * (`<exercisesDir>/<slug>.json`, antitrainer `rules` + `warnings`). Same
 * mapping as Payne's scripts/build-plan.js `techniqueFromCard` — the plan gets
 * it from there, a swapped-in exercise gets it from here.
 */
import { readFileSync } from 'node:fs';
import { join } from 'node:path';

export interface ExerciseTechnique {
  steps: { title: string; text: string }[];
  warnings: string[];
}

const SAFE_SLUG = /^[a-z0-9_-]+$/i;

export function readTechnique(exercisesDir: string, slug: string): ExerciseTechnique | undefined {
  if (!SAFE_SLUG.test(slug)) return undefined;
  let card: { rules?: unknown; warnings?: unknown };
  try {
    card = JSON.parse(readFileSync(join(exercisesDir, `${slug}.json`), 'utf8'));
  } catch {
    return undefined;
  }
  const str = (v: unknown) => (typeof v === 'string' ? v.trim() : '');
  const rules = Array.isArray(card?.rules) ? (card.rules as Array<Record<string, unknown>>) : [];
  const warns = Array.isArray(card?.warnings) ? (card.warnings as Array<Record<string, unknown>>) : [];
  const steps = rules.map((r) => ({ title: str(r?.text), text: str(r?.description) })).filter((s) => s.title || s.text);
  const warnings = warns.map((w) => str(w?.text)).filter(Boolean);
  return steps.length || warnings.length ? { steps, warnings } : undefined;
}
