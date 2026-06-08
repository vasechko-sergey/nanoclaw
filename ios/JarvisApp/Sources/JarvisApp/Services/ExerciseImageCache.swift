import Foundation
import UIKit

/// Disk-backed cache for exercise schematic images. Files live at
/// `<baseURL>/<slug>_<sha256>.jpg`. The sha256 in the filename pins
/// the cached blob to a specific version — if Payne updates the image
/// (new sha256 in manifest), the cache misses and re-fetches.
///
/// Concurrency: `has`/`image` read-only; `prefetch`/`write` mutate the
/// inflight set under a lock. `imageRequestSender` is invoked synchronously
/// per missing slug — the caller (transport) handles its own threading.
final class ExerciseImageCache {
    private let baseURL: URL
    private let imageRequestSender: (_ slug: String) -> Void

    private let lock = NSLock()
    private var inflightSlugs = Set<String>()

    init(baseURL: URL,
         imageRequestSender: @escaping (_ slug: String) -> Void) {
        self.baseURL = baseURL
        self.imageRequestSender = imageRequestSender
        try? FileManager.default.createDirectory(
            at: baseURL,
            withIntermediateDirectories: true
        )
    }

    /// Default install location: `<Library>/ExerciseImages/`.
    static func defaultBaseURL() -> URL {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("ExerciseImages", isDirectory: true)
    }

    // MARK: - Read-only

    func path(forSlug slug: String, sha256: String) -> URL {
        baseURL.appendingPathComponent("\(slug)_\(sha256).jpg")
    }

    func has(slug: String, sha256: String) -> Bool {
        FileManager.default.fileExists(atPath: path(forSlug: slug, sha256: sha256).path)
    }

    func image(slug: String, sha256: String) -> UIImage? {
        UIImage(contentsOfFile: path(forSlug: slug, sha256: sha256).path)
    }

    // MARK: - Prefetch / write

    /// Diff manifest against cache; fire `image_request` for every miss
    /// in parallel. Idempotent: re-calling with a partially-cached manifest
    /// only requests the still-missing slugs. De-dupes against in-flight.
    func prefetch(manifest: [WorkoutPlan.ImageManifestEntry]) {
        lock.lock()
        let toFetch: [String] = manifest.compactMap { entry in
            if has(slug: entry.slug, sha256: entry.sha256) { return nil }
            if inflightSlugs.contains(entry.slug) { return nil }
            inflightSlugs.insert(entry.slug)
            return entry.slug
        }
        lock.unlock()

        for slug in toFetch {
            imageRequestSender(slug)
        }
    }

    /// Called from the inbound dispatcher when an `image_blob` envelope
    /// arrives. Writes the bytes to disk and clears the in-flight marker.
    @discardableResult
    func write(slug: String, sha256: String, base64: String) throws -> URL {
        guard let data = Data(base64Encoded: base64) else {
            throw NSError(domain: "ExerciseImageCache", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "invalid base64 payload"])
        }
        let url = path(forSlug: slug, sha256: sha256)
        try data.write(to: url, options: .atomic)
        lock.lock()
        inflightSlugs.remove(slug)
        lock.unlock()
        return url
    }

    /// For tests / cleanup: drop all cached files.
    func clear() throws {
        let items = try FileManager.default.contentsOfDirectory(
            at: baseURL,
            includingPropertiesForKeys: nil
        )
        for url in items {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
