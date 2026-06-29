import Foundation

/// Downloads raw image bytes for a slug+sha. A seam so tests can inject a stub
/// instead of hitting the network.
protocol ImageDownloading: Sendable {
    func download(from url: URL, bearer: String) async throws -> Data
}

/// Production downloader. `URLSession` manages its own memory + backpressure and
/// runs entirely off the main thread — the whole point of moving image bytes off
/// the realtime WS stream.
struct URLSessionImageDownloader: ImageDownloading {
    func download(from url: URL, bearer: String) async throws -> Data {
        var req = URLRequest(url: url)
        req.timeoutInterval = 30
        req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return data
    }
}

/// Client half of by-reference image delivery. On an `image_ready { slug, sha256 }`
/// envelope, fetches the bytes over HTTP and stores them in the shared
/// `ExerciseImageCache` — OFF the main thread, with `URLSession`-managed memory.
///
/// This replaces the old `image_blob` path where ~1.7 MB of base64 was decoded
/// and disk-written on `@MainActor` per blob, which (drained as a burst on
/// connect) stalled the main thread / spiked memory and disconnected the client
/// before it reached the text behind the blobs. See
/// `docs/superpowers/specs/2026-06-28-ios-image-by-reference-design.md`.
final class ImageFetcher: @unchecked Sendable {
    private let cache: ExerciseImageCache
    private let downloader: ImageDownloading
    private let serverURL: @Sendable () -> String
    private let token: @Sendable () -> String?
    private let onFetched: @Sendable (String) -> Void
    private let lock = NSLock()
    private var inflight = Set<String>()

    init(
        cache: ExerciseImageCache,
        downloader: ImageDownloading = URLSessionImageDownloader(),
        serverURL: @escaping @Sendable () -> String = { ServerConfig.url },
        token: @escaping @Sendable () -> String? = { UserDefaults.standard.string(forKey: "bearerToken") },
        onFetched: @escaping @Sendable (String) -> Void
    ) {
        self.cache = cache
        self.downloader = downloader
        self.serverURL = serverURL
        self.token = token
        self.onFetched = onFetched
    }

    /// Ensure the bytes for slug+sha are on disk, then notify via `onFetched`.
    /// Already cached → notify immediately, no download. Concurrent fetches of
    /// the same slug+sha are de-duped to a single download.
    func fetch(slug: String, sha256: String) async {
        if cache.has(slug: slug, sha256: sha256) {
            onFetched(slug)
            return
        }
        let key = "\(slug)_\(sha256)"
        lock.lock()
        if inflight.contains(key) {
            lock.unlock()
            return
        }
        inflight.insert(key)
        lock.unlock()
        defer {
            lock.lock(); inflight.remove(key); lock.unlock()
        }

        guard let tok = token(), !tok.isEmpty,
              let url = Self.imageURL(base: serverURL(), slug: slug, sha256: sha256)
        else { return }
        do {
            let data = try await downloader.download(from: url, bearer: tok)
            try cache.store(slug: slug, sha256: sha256, data: data)
            onFetched(slug)
        } catch {
            Log.warn(.ws, "image fetch failed slug=\(slug): \(error)")
        }
    }

    /// Build `<httpBase>/ios/image?slug=&sha=` from the ws/host server string.
    /// Uses `ServerConfig.httpBase(from:)` for the shared ws→http(s) normalization.
    static func imageURL(base server: String, slug: String, sha256: String) -> URL? {
        var base = ServerConfig.httpBase(from: server)
        if base.hasSuffix("/") { base.removeLast() }
        guard var comps = URLComponents(string: base + "/ios/image") else { return nil }
        comps.queryItems = [
            URLQueryItem(name: "slug", value: slug),
            URLQueryItem(name: "sha", value: sha256),
        ]
        return comps.url
    }
}
