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

    /// LRU eviction bound. Cached exercise blobs are otherwise unbounded
    /// (Finding F28) — every fetched schematic accretes forever. We cap at 60
    /// entries, evicting least-recently-*written* files on write. Recency is the
    /// file modification date, stamped forward on each `write`/`store`. We do NOT
    /// bump on read: display resolves blobs by URL via `path`/`latestPath`, and
    /// bumping there would skew `latestPath`'s "newest blob for slug" semantics.
    /// A workout's working set (its ~6-10 exercises) stays well within 60, so
    /// write-time recency is an effective LRU for this access pattern.
    private let maxEntries: Int

    private let lock = NSLock()
    private var inflightSlugs = Set<String>()
    /// Guards recency-stamping + eviction; keeps `lastStamp` monotonic.
    private let ioLock = NSLock()
    private var lastStamp = Date.distantPast

    init(baseURL: URL,
         maxEntries: Int = 60,
         imageRequestSender: @escaping (_ slug: String) -> Void) {
        self.baseURL = baseURL
        self.maxEntries = maxEntries
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

    /// Newest cached file for a slug regardless of sha. Used for swap
    /// alternatives, whose sha256 isn't known until the `image_blob` lands.
    func latestPath(slug: String) -> URL? {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: baseURL, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return items
            .filter { $0.lastPathComponent.hasPrefix("\(slug)_") && $0.pathExtension == "jpg" }
            .max { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return da < db
            }
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
        stampUsed(url)
        lock.lock()
        inflightSlugs.remove(slug)
        lock.unlock()
        evictIfNeeded()
        return url
    }

    /// Persist already-decoded bytes (e.g. an HTTP-fetched `image_ready`).
    /// Mirrors `write(slug:sha256:base64:)` but takes raw `Data` — no base64
    /// round-trip. Atomic; clears the in-flight marker.
    @discardableResult
    func store(slug: String, sha256: String, data: Data) throws -> URL {
        let url = path(forSlug: slug, sha256: sha256)
        try data.write(to: url, options: .atomic)
        stampUsed(url)
        lock.lock()
        inflightSlugs.remove(slug)
        lock.unlock()
        evictIfNeeded()
        return url
    }

    // MARK: - LRU eviction (Finding F28)

    /// Stamp a file's modification date to a strictly-increasing "now" so the
    /// eviction scan orders blobs by recency. Monotonic within a session; across
    /// launches the first stamp is wall-clock now (newer than any prior mtime).
    private func stampUsed(_ url: URL) {
        ioLock.lock()
        let candidate = Date()
        let stamp = candidate > lastStamp ? candidate : lastStamp.addingTimeInterval(0.001)
        lastStamp = stamp
        ioLock.unlock()
        try? FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: url.path)
    }

    /// Drop least-recently-written `.jpg` blobs until within the entry cap.
    /// Cheap no-op in steady state (returns before sorting unless over cap).
    private func evictIfNeeded() {
        ioLock.lock(); defer { ioLock.unlock() }
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isRegularFileKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: baseURL, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]
        ) else { return }
        var entries: [(url: URL, date: Date)] = urls.compactMap { url in
            guard url.pathExtension == "jpg" else { return nil }
            let v = try? url.resourceValues(forKeys: keys)
            if v?.isRegularFile == false { return nil }
            return (url, v?.contentModificationDate ?? .distantPast)
        }
        guard entries.count > maxEntries else { return }
        entries.sort { $0.date < $1.date }      // least-recently-used first
        for e in entries.prefix(entries.count - maxEntries) {
            try? FileManager.default.removeItem(at: e.url)
        }
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
