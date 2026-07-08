import Foundation
import UIKit
import CryptoKit

/// Content-addressed on-disk store for chat image/file bytes. Files live at
/// `<baseURL>/<sha256>`. Modeled on `ExerciseImageCache`, but keyed purely by
/// content hash so identical bytes are stored once. Holds the bytes that used
/// to sit base64-encoded inside `messages.attachments_json`.
final class ChatImageStore {
    /// Process-wide instance, configured once at launch in `AppV2Bootstrap`
    /// before any session reads it. Tests reassign it to a temp-dir store in
    /// `setUp`. Deliberate mutable app-global: it is only ever assigned on the
    /// main thread at startup / in test setUp (never concurrently with reads),
    /// so no synchronization is needed.
    static var shared = ChatImageStore(baseURL: ChatImageStore.defaultBaseURL())

    private let baseURL: URL
    /// LRU eviction bounds. The on-disk blob directory is otherwise unbounded
    /// (Finding F28) — every inbound/outbound chat image accretes forever. We
    /// cap it at 150 MB OR 300 entries, whichever bound is hit first, evicting
    /// least-recently-used files on write. "Recency" is the file's modification
    /// date, stamped to a strictly-increasing value on every write AND on every
    /// disk read (a view counts as a use), so a frequently-viewed image is not
    /// evicted just because it was written long ago.
    private let maxBytes: Int
    private let maxEntries: Int
    /// Serializes recency-stamping + eviction (the read-modify-scan of the
    /// directory) and keeps `lastStamp` monotonic across concurrent writers.
    private let ioLock = NSLock()
    private var lastStamp = Date.distantPast
    /// Decoded-thumbnail cache keyed by "<sha>@<maxPixel>". Cost-bounded so
    /// photo-heavy timelines don't thrash. NSCache also evicts under pressure.
    private let thumbCache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.totalCostLimit = 64 * 1024 * 1024
        return c
    }()

    init(baseURL: URL, maxBytes: Int = 150 * 1024 * 1024, maxEntries: Int = 300) {
        self.baseURL = baseURL
        self.maxBytes = maxBytes
        self.maxEntries = maxEntries
        try? FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
    }

    /// `<Library>/ChatImages/`.
    static func defaultBaseURL() -> URL {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("ChatImages", isDirectory: true)
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func path(forSHA sha: String) -> URL { baseURL.appendingPathComponent(sha) }

    func has(sha: String) -> Bool {
        FileManager.default.fileExists(atPath: path(forSHA: sha).path)
    }

    /// Persist bytes, returning their sha256. Idempotent: a file already present
    /// for that hash is left untouched (content-addressed → automatic dedup).
    @discardableResult
    func write(_ data: Data) -> String {
        let sha = Self.sha256Hex(data)
        let url = path(forSHA: sha)
        if !FileManager.default.fileExists(atPath: url.path) {
            try? data.write(to: url, options: .atomic)
        }
        stampUsed(url)      // fresh write OR dedup-hit → most-recently-used
        evictIfNeeded()
        return sha
    }

    func bytes(sha: String) -> Data? {
        let url = path(forSHA: sha)
        guard let data = try? Data(contentsOf: url) else { return nil }
        stampUsed(url)      // a read is a use → bump recency for true LRU
        return data
    }

    /// Decode downsampled to `maxPixel` on the longest edge. No caching — used
    /// by the full-screen view, which only resolves on an explicit tap.
    func fullImage(sha: String, maxPixel: CGFloat) -> UIImage? {
        guard let data = bytes(sha: sha) else { return nil }
        return Self.downsample(data, maxPixel: maxPixel)
    }

    /// Small decode for the chat row, cached by sha + size. On a cache MISS this
    /// does synchronous disk read + decode — callers on the main thread should
    /// ensure it runs off-main (the timeline maps rows on a background scheduler)
    /// or accept a one-time hitch on first render of a fresh image.
    func thumbnail(sha: String, maxPixel: CGFloat = 480) -> UIImage? {
        let key = "\(sha)@\(Int(maxPixel))" as NSString
        if let hit = thumbCache.object(forKey: key) { return hit }
        guard let img = fullImage(sha: sha, maxPixel: maxPixel) else { return nil }
        let cost = Int(img.size.width * img.scale * img.size.height * img.scale) * 4
        thumbCache.setObject(img, forKey: key, cost: cost)
        return img
    }

    func clear() throws {
        let items = try FileManager.default.contentsOfDirectory(at: baseURL, includingPropertiesForKeys: nil)
        for url in items { try? FileManager.default.removeItem(at: url) }
        thumbCache.removeAllObjects()
    }

    // MARK: - LRU eviction (Finding F28)

    /// Stamp a file's modification date to a strictly-increasing "now" so the
    /// eviction scan can order blobs by recency. Monotonic within a session (a
    /// burst of writes/reads in the same millisecond still orders deterministically);
    /// across launches the first stamp is wall-clock now, far newer than any
    /// mtime left by a prior run, so ordering survives restarts.
    private func stampUsed(_ url: URL) {
        ioLock.lock()
        let candidate = Date()
        let stamp = candidate > lastStamp ? candidate : lastStamp.addingTimeInterval(0.001)
        lastStamp = stamp
        ioLock.unlock()
        try? FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: url.path)
    }

    /// Drop least-recently-used blobs until the directory is within BOTH the
    /// entry cap and the byte cap. Cheap no-op in steady state (returns before
    /// sorting unless a cap is actually exceeded).
    private func evictIfNeeded() {
        ioLock.lock(); defer { ioLock.unlock() }
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: baseURL, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]
        ) else { return }
        var entries: [(url: URL, date: Date, size: Int)] = urls.compactMap { url in
            let v = try? url.resourceValues(forKeys: keys)
            if v?.isRegularFile == false { return nil }
            return (url, v?.contentModificationDate ?? .distantPast, v?.fileSize ?? 0)
        }
        var total = entries.reduce(0) { $0 + $1.size }
        var count = entries.count
        guard count > maxEntries || total > maxBytes else { return }
        entries.sort { $0.date < $1.date }      // least-recently-used first
        for e in entries {
            if count <= maxEntries && total <= maxBytes { break }
            try? FileManager.default.removeItem(at: e.url)
            total -= e.size
            count -= 1
        }
    }

    private static func downsample(_ data: Data, maxPixel: CGFloat) -> UIImage? {
        if let src = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
           let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [
               kCGImageSourceCreateThumbnailFromImageAlways: true,
               kCGImageSourceCreateThumbnailWithTransform: true,
               kCGImageSourceShouldCacheImmediately: true,
               kCGImageSourceThumbnailMaxPixelSize: maxPixel,
           ] as CFDictionary) {
            return UIImage(cgImage: cg)
        }
        return UIImage(data: data)
    }
}
