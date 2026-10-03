import Foundation

/// Slug → cached demo-image URL, shared by the plan preview, the runner and the
/// swap sheet.
///
/// `live` is the coordinator's plan (nil before the runner exists), `snapshot`
/// the plan the full-screen cover was opened with. They diverge the moment a
/// mid-workout swap rewrites the coordinator's plan.
enum ExerciseImageResolution {

    static func url(slug: String,
                    live: WorkoutPlan?,
                    snapshot: WorkoutPlan,
                    cache: ExerciseImageCache) -> URL? {
        // The coordinator's plan is authoritative once the runner owns one: a
        // mid-workout swap rewrites ITS manifest, while `snapshot` keeps the
        // entries the cover was opened with and would resolve the swapped-in
        // exercise to nothing.
        let manifest = (live ?? snapshot).imageManifest
        // No manifest entry → the plan carries no image for this exercise (e.g.
        // one Payne has no demo for). Show the placeholder, NOT a stale cached
        // blob from a past plan — keeps a unified "no demo" look.
        guard let entry = manifest.first(where: { $0.slug == slug }) else { return nil }
        if cache.has(slug: entry.slug, sha256: entry.sha256) {
            return cache.path(forSlug: entry.slug, sha256: entry.sha256)
        }
        // Entry present but its sha isn't cached yet (sha drift or not-yet-
        // delivered) → newest cached blob for the slug.
        return cache.latestPath(slug: slug)
    }
}
