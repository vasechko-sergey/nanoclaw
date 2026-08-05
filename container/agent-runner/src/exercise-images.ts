/**
 * Exercise-image asset resolution, shared by the two sides that must agree on
 * the exact bytes and hash of a workout image:
 *   - poll-loop `serveImageRequests` — reads the asset and serves `image_blob`.
 *   - workout `workout.start_plan` — auto-derives `image_manifest` when Payne
 *     omits it, so iOS knows which slugs to prefetch.
 *
 * The manifest sha256 and the served-blob sha256 MUST match, or iOS caches under
 * one key and looks up under another (silent miss). Keeping the dir, the
 * extension priority, and the hash in one module is what guarantees that.
 */
import { createHash } from 'node:crypto';
import { existsSync, readFileSync } from 'node:fs';
import { join } from 'node:path';

/** Where an agent's exercise images live inside its container workspace. */
export const DEFAULT_EXERCISES_DIR = '/workspace/agent/exercises';

/** Extension priority: an animated `.gif` wins over a still `.jpg`/`.png`. */
export const IMAGE_EXTS = ['.gif', '.jpg', '.png'] as const;

/**
 * First existing image file for a slug, honoring the extension priority. `null`
 * when the slug is empty or no asset exists (caller keeps a placeholder).
 */
export function resolveExerciseImagePath(
  slug: string,
  exercisesDir: string = DEFAULT_EXERCISES_DIR,
): string | null {
  if (!slug) return null;
  return IMAGE_EXTS.map((ext) => join(exercisesDir, `${slug}${ext}`)).find((p) => existsSync(p)) ?? null;
}

/** sha256 hex of a file's raw bytes — the exact key the image_blob responder emits. */
export function hashImageFile(path: string): string {
  return createHash('sha256').update(readFileSync(path)).digest('hex');
}

export interface ImageManifestEntry {
  slug: string;
  sha256: string;
}

/**
 * Build an `image_manifest` from exercise slugs by hashing the on-disk asset the
 * responder would serve. Slugs with no asset are skipped (iOS keeps its
 * placeholder), exactly like `serveImageRequests`. Repeated/empty slugs are
 * dropped so the manifest is a clean set.
 */
export function buildImageManifest(
  slugs: string[],
  exercisesDir: string = DEFAULT_EXERCISES_DIR,
): ImageManifestEntry[] {
  const out: ImageManifestEntry[] = [];
  const seen = new Set<string>();
  for (const slug of slugs) {
    if (!slug || seen.has(slug)) continue;
    seen.add(slug);
    const path = resolveExerciseImagePath(slug, exercisesDir);
    if (!path) continue;
    try {
      out.push({ slug, sha256: hashImageFile(path) });
    } catch {
      // Unreadable asset → skip; iOS keeps its placeholder rather than caching a
      // broken key. Mirrors the responder's try/catch.
    }
  }
  return out;
}
