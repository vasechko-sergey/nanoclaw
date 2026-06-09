/**
 * One-shot: import purchased programs + exercise library + past weights
 * from antitrainer.app into Payne's group folder.
 *
 * Writes to: groups/payne/{exercises,programs,sessions}/
 *
 * Usage:
 *   ANTITRAINER_TOKEN='540088|...' pnpm exec tsx scripts/import-antitrainer.ts
 *
 * Idempotent — re-runs overwrite existing files (intentional, so weight
 * updates / new exercises sync).
 *
 * Output structure:
 *   exercises/<slug>.json     — { id, name, name_ru, slug, primary_muscle_groups,
 *                                 secondary_muscle_groups, equipment, axial_load,
 *                                 image, refs, rules[], warnings[],
 *                                 antitrainer_id, gif_url, video_url }
 *   exercises/<slug>.jpg      — schematic thumbnail (default conversion)
 *   programs/antitrainer-<program_id>.json
 *                             — full program JSON: name, weeks, days[], each
 *                                 with exercises[] referencing slug
 *   sessions/baseline-from-antitrainer.json
 *                             — synthetic baseline: {exercises: [{slug, weight}]}
 *                                 from progress.exercises_complete across all
 *                                 trainings.
 */
import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = path.resolve(__dirname, '..');
const PAYNE_DIR = path.join(REPO_ROOT, 'groups', 'payne');
const EXERCISES_DIR = path.join(PAYNE_DIR, 'exercises');
const PROGRAMS_DIR = path.join(PAYNE_DIR, 'programs');
const SESSIONS_DIR = path.join(PAYNE_DIR, 'sessions');

const BASE = 'https://lk.antitrainer.app/api';
const TOKEN = process.env.ANTITRAINER_TOKEN;
if (!TOKEN) {
  console.error('Set ANTITRAINER_TOKEN env var (Bearer token from browser devtools).');
  process.exit(2);
}

// ── HTTP helpers ──────────────────────────────────────────────────────────

async function get<T = unknown>(path: string): Promise<T> {
  const res = await fetch(`${BASE}${path}`, {
    headers: {
      Authorization: `Bearer ${TOKEN}`,
      Accept: 'application/json',
    },
  });
  if (!res.ok) {
    throw new Error(`GET ${path} → ${res.status}`);
  }
  return res.json() as Promise<T>;
}

async function downloadImage(url: string, outPath: string): Promise<void> {
  const res = await fetch(url);
  if (!res.ok) throw new Error(`download ${url} → ${res.status}`);
  const buf = Buffer.from(await res.arrayBuffer());
  fs.writeFileSync(outPath, buf);
}

// ── Slug + transliteration ────────────────────────────────────────────────

const CYR_MAP: Record<string, string> = {
  а: 'a', б: 'b', в: 'v', г: 'g', д: 'd', е: 'e', ё: 'yo',
  ж: 'zh', з: 'z', и: 'i', й: 'y', к: 'k', л: 'l', м: 'm',
  н: 'n', о: 'o', п: 'p', р: 'r', с: 's', т: 't', у: 'u',
  ф: 'f', х: 'h', ц: 'ts', ч: 'ch', ш: 'sh', щ: 'shch',
  ъ: '', ы: 'y', ь: '', э: 'e', ю: 'yu', я: 'ya',
};

function slugify(name: string): string {
  return name
    .toLowerCase()
    .replace(/./g, (c) => CYR_MAP[c] ?? c)
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-|-$/g, '')
    .slice(0, 60);
}

// ── Muscle-group mapping ──────────────────────────────────────────────────
// antitrainer muscles → our muscle_groups.md slugs

const MUSCLE_MAP: Record<string, string[]> = {
  Грудь: ['chest_middle'],
  'Верх груди': ['chest_upper'],
  Спина: ['back_lats'],
  Широчайшие: ['back_lats'],
  Трапеции: ['back_traps'],
  'Средняя спина': ['back_rhomboids'],
  Бицепс: ['biceps'],
  Бицепсы: ['biceps'],
  Трицепс: ['triceps'],
  Трицепсы: ['triceps'],
  Предплечья: ['forearms'],
  Дельты: ['delts_side'],
  'Передние дельты': ['delts_front'],
  'Средние дельты': ['delts_side'],
  'Задние дельты': ['delts_rear'],
  Плечи: ['delts_side'],
  Квадрицепс: ['legs_quads'],
  Квадрицепсы: ['legs_quads'],
  Ноги: ['legs_quads', 'legs_hams', 'legs_glutes'],
  'Бицепс бедра': ['legs_hams'],
  Ягодицы: ['legs_glutes'],
  Икры: ['legs_calves'],
  Голень: ['legs_calves'],
  Пресс: ['core_abs'],
  Кор: ['core_abs'],
  Косые: ['core_obliques'],
  'Верх тела': [],
  Руки: ['biceps', 'triceps'],
  Кардио: [],
  Поясница: ['lumbar_erectors'],
};

function mapMuscles(muscles: Array<{ name: string; filtering?: number }>): {
  primary: string[];
  secondary: string[];
} {
  const primary = new Set<string>();
  const secondary = new Set<string>();
  for (const m of muscles) {
    const slugs = MUSCLE_MAP[m.name] ?? [];
    // filtering=1 means primary on antitrainer side; 0 = secondary
    const target = m.filtering === 1 ? primary : secondary;
    for (const s of slugs) target.add(s);
  }
  return {
    primary: Array.from(primary),
    secondary: Array.from(secondary).filter((s) => !primary.has(s)),
  };
}

// ── Axial-load detection (Сергея ограничение) ─────────────────────────────

const AXIAL_KEYWORDS = [
  'присед со штангой',
  'приседания со штангой',
  'становая',
  'румынск',
  'армейский жим',
  'жим штанги стоя',
];

function isAxial(name: string): boolean {
  const n = name.toLowerCase();
  return AXIAL_KEYWORDS.some((k) => n.includes(k));
}

// ── Types ─────────────────────────────────────────────────────────────────

interface AtMuscle {
  id: number;
  name: string;
  filtering?: number;
}

interface AtExercise {
  id: number;
  name: string;
  description?: string | null;
  thumbnail?: { url: string; sizes?: { default?: { url: string } } };
  video?: { url: string | null };
  gif_video?: { url: string | null };
  rules?: Array<{ text: string; description: string }>;
  warnings?: Array<{ text: string }>;
  type_of_execution?: number;
  execution_rest?: string;
  muscles?: AtMuscle[];
}

interface AtTrainingExercise {
  id: number;
  order: number;
  approaches: number | null;
  repeat_from: number | null;
  repeat_to: number | null;
  execution_duration_seconds: number | null;
  exercise: AtExercise;
  superset?: unknown;
  training_id: number;
}

interface AtTraining {
  id: number;
  description?: string;
  duration: string;
  order: number;
  display_order: number;
  muscles: AtMuscle[];
  exercises: AtTrainingExercise[];
}

interface AtProgramTraining {
  id: number;
  order: number;
  program_week_id: number;
  display_order: number;
  muscles: AtMuscle[];
  progress?: {
    exercises_complete?: Record<string, number>;
    complete: boolean;
    active: boolean;
    is_completed: boolean;
  };
}

interface AtProgram {
  id: number;
  name: string;
  slug: string;
  description?: string;
  count_trainings_in_week: number;
  trainings_count: number;
  trainings: AtProgramTraining[];
}

// ── Main ──────────────────────────────────────────────────────────────────

const exerciseCache = new Map<number, { slug: string; card: Record<string, unknown> }>();
const baselineWeights = new Map<number, number>(); // exercise.id (antitrainer) → kg

function ensureDir(p: string) {
  fs.mkdirSync(p, { recursive: true });
}

async function importExerciseCard(at: AtExercise): Promise<{ slug: string }> {
  const existing = exerciseCache.get(at.id);
  if (existing) return existing;

  const slug = slugify(at.name);
  const muscles = mapMuscles(at.muscles ?? []);
  const card: Record<string, unknown> = {
    slug,
    name_ru: at.name,
    name_en: null,
    primary_muscle_groups: muscles.primary,
    secondary_muscle_groups: muscles.secondary,
    equipment: [], // antitrainer не отдаёт явно, заполняется вручную
    axial_load: isAxial(at.name),
    image: at.thumbnail ? `${slug}.jpg` : null,
    refs: [`antitrainer://exercise/${at.id}`],
    notes: at.description ?? null,
    rules: at.rules ?? [],
    warnings: at.warnings ?? [],
    antitrainer_id: at.id,
    gif_url: at.gif_video?.url ?? null,
    video_url: at.video?.url ?? null,
    rest_default_sec: at.execution_rest ? hmsToSec(at.execution_rest) : null,
    created_at: new Date().toISOString(),
  };

  // Download thumbnail (prefer default-jpg conversion).
  const thumbUrl = at.thumbnail?.sizes?.default?.url ?? at.thumbnail?.url;
  if (thumbUrl) {
    try {
      await downloadImage(thumbUrl, path.join(EXERCISES_DIR, `${slug}.jpg`));
    } catch (err) {
      console.warn(`  ! thumbnail failed for ${slug}: ${(err as Error).message}`);
      card.image = null;
    }
  }

  fs.writeFileSync(path.join(EXERCISES_DIR, `${slug}.json`), JSON.stringify(card, null, 2));
  exerciseCache.set(at.id, { slug, card });
  return { slug };
}

function hmsToSec(hms: string): number | null {
  const m = hms.match(/^(\d+):(\d+):(\d+)$/);
  if (!m) return null;
  return Number(m[1]) * 3600 + Number(m[2]) * 60 + Number(m[3]);
}

async function importProgram(programId: number): Promise<void> {
  console.log(`Program ${programId}: fetching...`);
  const { data: prog } = await get<{ data: AtProgram }>(`/programs/${programId}`);
  console.log(`  ${prog.name}`);
  console.log(`  ${prog.trainings_count} trainings, ${prog.count_trainings_in_week}/week`);

  const programOut: Record<string, unknown> = {
    id: `antitrainer-${prog.id}`,
    source: 'antitrainer',
    antitrainer_id: prog.id,
    name: prog.name,
    slug: prog.slug,
    description: prog.description ?? null,
    trainings_per_week: prog.count_trainings_in_week,
    total_trainings: prog.trainings_count,
    days: [] as unknown[],
    imported_at: new Date().toISOString(),
  };

  // Walk each training.
  for (const t of prog.trainings) {
    console.log(`  Training ${t.id} (order ${t.order}):`);
    const { data: tr } = await get<{ data: AtTraining }>(`/trainings/${t.id}`);

    const day: Record<string, unknown> = {
      antitrainer_training_id: t.id,
      order: t.order,
      week_id: t.program_week_id,
      display_order: t.display_order,
      name: tr.description ?? `Тренировка ${t.order}`,
      duration_planned: tr.duration,
      muscles: tr.muscles.map((m) => m.name),
      exercises: [] as unknown[],
    };

    for (const ex of tr.exercises) {
      const { slug } = await importExerciseCard(ex.exercise);
      console.log(`    ${slug}  ${ex.approaches ?? '?'}×${ex.repeat_from ?? '?'}-${ex.repeat_to ?? '?'}`);
      (day.exercises as unknown[]).push({
        exercise_slug: slug,
        antitrainer_exercise_instance_id: ex.id,
        target_sets: ex.approaches,
        target_reps: ex.repeat_from === ex.repeat_to
          ? String(ex.repeat_from ?? '')
          : `${ex.repeat_from ?? ''}-${ex.repeat_to ?? ''}`,
        target_rir: 2, // default; antitrainer не передаёт RIR
        rest_sec: ex.exercise.execution_rest ? hmsToSec(ex.exercise.execution_rest) : 120,
        execution_duration_seconds: ex.execution_duration_seconds,
        order: ex.order,
      });
    }

    // Extract baseline weights from progress.exercises_complete (per-program-training).
    if (t.progress?.exercises_complete) {
      for (const [exId, weight] of Object.entries(t.progress.exercises_complete)) {
        const id = Number(exId);
        if (weight > 0 && !baselineWeights.has(id)) {
          baselineWeights.set(id, weight);
        }
      }
    }

    (programOut.days as unknown[]).push(day);
  }

  const outPath = path.join(PROGRAMS_DIR, `antitrainer-${prog.id}.json`);
  fs.writeFileSync(outPath, JSON.stringify(programOut, null, 2));
  console.log(`  → ${path.relative(REPO_ROOT, outPath)}`);
}

interface AtDiary {
  id: number;
  weight: number;
  repeats: number | null;
  duration: number | null;
  notes: string | null;
  week?: { id: number; name: string; color: string; icon: string };
  training_id: number;
  exercise_id: number;
  created_at: string;
  updated_at: string;
}

/**
 * Pull every diary entry for every imported exercise, regroup by
 * antitrainer training_id, and write one session JSON per training.
 *
 * Each diary entry == one logged set. reps_in_reserve isn't tracked by
 * antitrainer — we infer it from `week.name` (Лёгкая/Средняя/Тяжёлая)
 * since that's the protocol Sergei was running.
 */
async function importDiaries(): Promise<{
  sessionsWritten: number;
  totalSets: number;
}> {
  // training_id -> { date, week_label, exercises: { slug -> sets[] } }
  type SessionAccum = {
    date: string;
    week_label?: string;
    week_color?: string;
    exercises: Map<string, Array<Record<string, unknown>>>;
  };
  const sessions = new Map<number, SessionAccum>();
  let totalSets = 0;

  const uniqueAntitrainerIds = Array.from(new Set([...exerciseCache.keys()]));
  console.log(`Diaries: walking ${uniqueAntitrainerIds.length} exercises...`);

  for (const exId of uniqueAntitrainerIds) {
    const cached = exerciseCache.get(exId);
    if (!cached) continue;

    // Pagination — pull all entries, page-by-page.
    let page = 1;
    let pagesSeen = 0;
    for (;;) {
      const url = `/diaries?filter%5Bexercise_id%5D=${exId}&include%5B0%5D=week&page=${page}&per_page=200`;
      let resp: { data: AtDiary[]; meta?: { last_page: number; current_page: number } };
      try {
        resp = await get<{ data: AtDiary[]; meta?: { last_page: number; current_page: number } }>(url);
      } catch (err) {
        console.warn(`  ! diaries ${exId} p${page} failed: ${(err as Error).message}`);
        break;
      }
      const rows = resp.data ?? [];
      if (rows.length === 0) break;

      for (const row of rows) {
        const tid = row.training_id;
        let acc = sessions.get(tid);
        if (!acc) {
          acc = {
            date: row.created_at.slice(0, 10),
            week_label: row.week?.name,
            week_color: row.week?.color,
            exercises: new Map(),
          };
          sessions.set(tid, acc);
        }
        // Use the earliest ts as session date.
        if (row.created_at.slice(0, 10) < acc.date) acc.date = row.created_at.slice(0, 10);

        let setList = acc.exercises.get(cached.slug);
        if (!setList) {
          setList = [];
          acc.exercises.set(cached.slug, setList);
        }
        setList.push({
          reps: row.repeats ?? 0,
          weight: row.weight,
          reps_in_reserve: rirFromWeek(row.week?.name),
          duration_sec: row.duration,
          notes: row.notes,
          ts: row.created_at,
          antitrainer_diary_id: row.id,
        });
        totalSets++;
      }

      pagesSeen++;
      const meta = resp.meta;
      if (!meta || meta.current_page >= meta.last_page) break;
      page++;
      if (page > 50) break; // safety
    }
    if (pagesSeen > 0) {
      const total = Array.from(sessions.values()).reduce(
        (n, s) => n + (s.exercises.get(cached.slug)?.length ?? 0),
        0
      );
      console.log(`  ${cached.slug.padEnd(40)} ${total} sets (${pagesSeen} pages)`);
    }
  }

  // Write each session.
  let written = 0;
  for (const [tid, acc] of sessions) {
    const exercises = Array.from(acc.exercises, ([slug, sets]) => ({
      exercise_slug: slug,
      sets: sets.sort((a, b) => String(a.ts).localeCompare(String(b.ts))),
    }));
    const out = {
      antitrainer_training_id: tid,
      date: acc.date,
      week_label: acc.week_label ?? null,
      week_color: acc.week_color ?? null,
      source: 'antitrainer',
      imported_at: new Date().toISOString(),
      exercises,
    };
    const fname = `${acc.date}-at-${tid}.json`;
    fs.writeFileSync(path.join(SESSIONS_DIR, fname), JSON.stringify(out, null, 2));
    written++;
  }
  return { sessionsWritten: written, totalSets };
}

/** Map antitrainer week intensity label → default reps_in_reserve. */
function rirFromWeek(label?: string): number {
  switch (label) {
    case 'Лёгкая': return 4;
    case 'Средняя': return 2;
    case 'Тяжёлая': return 1;
    default: return 2;
  }
}

async function main() {
  ensureDir(EXERCISES_DIR);
  ensureDir(PROGRAMS_DIR);
  ensureDir(SESSIONS_DIR);

  console.log('Listing purchased programs...');
  const { data: programs } = await get<{ data: Array<{ id: number; name: string }> }>(
    '/programs?filter%5Bpurchased%5D=1'
  );
  console.log(`Found ${programs.length}:`);
  for (const p of programs) console.log(`  ${p.id}  ${p.name}`);

  for (const p of programs) {
    await importProgram(p.id);
  }

  console.log('');
  const diaryStats = await importDiaries();

  console.log('');
  console.log('Summary:');
  console.log(`  ${exerciseCache.size} unique exercise cards`);
  console.log(`  ${programs.length} programs`);
  console.log(`  ${diaryStats.sessionsWritten} sessions (${diaryStats.totalSets} sets)`);
  console.log('');
  console.log('Inspect:  ls groups/payne/exercises  ls groups/payne/programs  ls groups/payne/sessions');
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
