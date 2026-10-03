import XCTest
@testable import Jarvis

/// Which plan the runner resolves demo images against.
///
/// 2026-10-03: a mid-workout swap showed a placeholder even though the bytes
/// were already on disk (the sheet had fetched a thumbnail for every
/// alternative, and `applySwap` had added the manifest entry). The runner was
/// resolving against the plan captured when the full-screen cover opened —
/// a value copy that a swap never touches — so the new slug had no manifest
/// entry and the strict "no entry ⇒ placeholder" guard fired.
final class ExerciseImageResolutionTests: XCTestCase {

    private var tmpDir: URL!

    override func setUpWithError() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExerciseImageResolutionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    private func plan(manifest: [WorkoutPlan.ImageManifestEntry]) -> WorkoutPlan {
        WorkoutPlan(
            workoutId: "w1", dayName: "Верх A", week: 2, intensityLabel: "тяжёлая",
            exercises: [ExercisePlan(exerciseSlug: "ex-0", targetSets: 4, targetReps: "8-10",
                                     targetRir: 2, restSec: 120)],
            imageManifest: manifest
        )
    }

    func test_url_prefersLivePlanOverOpeningSnapshot() throws {
        let cache = ExerciseImageCache(baseURL: tmpDir) { _ in }
        try cache.write(slug: "ex-0-alt", sha256: "sha-alt", base64: tinyJpegBase64())
        let snapshot = plan(manifest: [.init(slug: "ex-0", sha256: "sha-0")])
        let live = plan(manifest: [.init(slug: "ex-0-alt", sha256: "sha-alt")])

        let url = ExerciseImageResolution.url(slug: "ex-0-alt", live: live, snapshot: snapshot, cache: cache)
        XCTAssertEqual(url, cache.path(forSlug: "ex-0-alt", sha256: "sha-alt"))
    }

    /// The guard itself stays: an exercise with no manifest entry anywhere shows
    /// the placeholder, never a stale blob from an earlier plan.
    func test_url_noManifestEntry_returnsNil() throws {
        let cache = ExerciseImageCache(baseURL: tmpDir) { _ in }
        try cache.write(slug: "ex-9", sha256: "sha-9", base64: tinyJpegBase64())
        let snapshot = plan(manifest: [])
        XCTAssertNil(ExerciseImageResolution.url(slug: "ex-9", live: nil, snapshot: snapshot, cache: cache))
    }

    /// Entry present but its sha isn't cached yet (blob still in flight, or sha
    /// drift) → newest cached blob for the slug.
    func test_url_shaNotCached_fallsBackToLatestBlob() throws {
        let cache = ExerciseImageCache(baseURL: tmpDir) { _ in }
        try cache.write(slug: "ex-0", sha256: "old-sha", base64: tinyJpegBase64())
        let snapshot = plan(manifest: [.init(slug: "ex-0", sha256: "new-sha")])
        XCTAssertEqual(ExerciseImageResolution.url(slug: "ex-0", live: nil, snapshot: snapshot, cache: cache),
                       cache.path(forSlug: "ex-0", sha256: "old-sha"))
    }

    /// Preview phase: no coordinator exists yet, so the snapshot IS the plan.
    func test_url_noLivePlan_usesSnapshot() throws {
        let cache = ExerciseImageCache(baseURL: tmpDir) { _ in }
        try cache.write(slug: "ex-0", sha256: "sha-0", base64: tinyJpegBase64())
        let snapshot = plan(manifest: [.init(slug: "ex-0", sha256: "sha-0")])
        XCTAssertEqual(ExerciseImageResolution.url(slug: "ex-0", live: nil, snapshot: snapshot, cache: cache),
                       cache.path(forSlug: "ex-0", sha256: "sha-0"))
    }

    // 1x1 JPEG (smallest valid).
    private func tinyJpegBase64() -> String {
        "/9j/4AAQSkZJRgABAQEASABIAAD/2wBDAAEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQH/2wBDAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQH/wAARCAABAAEDASIAAhEBAxEB/8QAFQABAQAAAAAAAAAAAAAAAAAAAAv/xAAUEAEAAAAAAAAAAAAAAAAAAAAA/8QAFAEBAAAAAAAAAAAAAAAAAAAAAP/EABQRAQAAAAAAAAAAAAAAAAAAAAD/2gAMAwEAAhEDEQA/AKp//9k="
    }
}
