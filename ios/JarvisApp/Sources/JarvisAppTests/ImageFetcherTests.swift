import XCTest
@testable import Jarvis

final class ImageFetcherTests: XCTestCase {

    private var tmpDir: URL!

    override func setUpWithError() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImageFetcherTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    private func makeCache() -> ExerciseImageCache {
        ExerciseImageCache(baseURL: tmpDir) { _ in }
    }

    func test_fetch_downloadsStoresBytesAndNotifies() async throws {
        let cache = makeCache()
        let bytes = Data("FAKEPNGBYTES".utf8)
        let dl = StubDownloader(mode: .success(bytes))
        let box = FetchedBox()
        let fetcher = ImageFetcher(
            cache: cache, downloader: dl,
            serverURL: { "wss://jarvis.example" }, token: { "tok" },
            onFetched: { box.append($0) }
        )

        await fetcher.fetch(slug: "ex", sha256: "abc")

        XCTAssertTrue(cache.has(slug: "ex", sha256: "abc"))
        XCTAssertEqual(try Data(contentsOf: cache.path(forSlug: "ex", sha256: "abc")), bytes)
        XCTAssertEqual(box.values, ["ex"])
        XCTAssertEqual(dl.callCount, 1)
        XCTAssertEqual(dl.calls.first?.absoluteString, "https://jarvis.example/ios/image?slug=ex&sha=abc")
    }

    func test_fetch_skipsDownloadWhenAlreadyCached() async throws {
        let cache = makeCache()
        try cache.store(slug: "ex", sha256: "abc", data: Data("x".utf8))
        let dl = StubDownloader(mode: .success(Data("y".utf8)))
        let box = FetchedBox()
        let fetcher = ImageFetcher(
            cache: cache, downloader: dl,
            serverURL: { "wss://h" }, token: { "tok" }, onFetched: { box.append($0) }
        )

        await fetcher.fetch(slug: "ex", sha256: "abc")

        XCTAssertEqual(dl.callCount, 0, "cached slug+sha must not re-download")
        XCTAssertEqual(box.values, ["ex"], "still notifies so the UI refreshes")
    }

    func test_fetch_downloadFailure_doesNotStoreOrNotify() async {
        let cache = makeCache()
        let dl = StubDownloader(mode: .failure(URLError(.timedOut)))
        let box = FetchedBox()
        let fetcher = ImageFetcher(
            cache: cache, downloader: dl,
            serverURL: { "wss://h" }, token: { "tok" }, onFetched: { box.append($0) }
        )

        await fetcher.fetch(slug: "ex", sha256: "abc")

        XCTAssertFalse(cache.has(slug: "ex", sha256: "abc"))
        XCTAssertTrue(box.values.isEmpty)
    }

    func test_fetch_concurrentSameKey_downloadsOnce() async {
        let cache = makeCache()
        let dl = StubDownloader(mode: .success(Data("z".utf8)), delayNanos: 80_000_000)
        let fetcher = ImageFetcher(
            cache: cache, downloader: dl,
            serverURL: { "wss://h" }, token: { "tok" }, onFetched: { _ in }
        )

        async let a: Void = fetcher.fetch(slug: "ex", sha256: "abc")
        async let b: Void = fetcher.fetch(slug: "ex", sha256: "abc")
        _ = await (a, b)

        XCTAssertEqual(dl.callCount, 1, "concurrent fetches of the same slug+sha de-dupe to one download")
        XCTAssertTrue(cache.has(slug: "ex", sha256: "abc"))
    }

    func test_fetch_missingToken_doesNothing() async {
        let cache = makeCache()
        let dl = StubDownloader(mode: .success(Data("z".utf8)))
        let fetcher = ImageFetcher(
            cache: cache, downloader: dl,
            serverURL: { "wss://h" }, token: { nil }, onFetched: { _ in }
        )
        await fetcher.fetch(slug: "ex", sha256: "abc")
        XCTAssertEqual(dl.callCount, 0)
        XCTAssertFalse(cache.has(slug: "ex", sha256: "abc"))
    }

    func test_imageURL_normalizesSchemeAndPath() {
        XCTAssertEqual(
            ImageFetcher.imageURL(base: "wss://h.test", slug: "s", sha256: "x")?.absoluteString,
            "https://h.test/ios/image?slug=s&sha=x"
        )
        XCTAssertEqual(
            ImageFetcher.imageURL(base: "ws://h.test", slug: "s", sha256: "x")?.absoluteString,
            "http://h.test/ios/image?slug=s&sha=x"
        )
        XCTAssertEqual(
            ImageFetcher.imageURL(base: "100.64.0.1:3001", slug: "s", sha256: "x")?.absoluteString,
            "http://100.64.0.1:3001/ios/image?slug=s&sha=x"
        )
        XCTAssertEqual(
            ImageFetcher.imageURL(base: "https://h.test/", slug: "s", sha256: "x")?.absoluteString,
            "https://h.test/ios/image?slug=s&sha=x"
        )
    }
}

// MARK: - Test doubles

final class StubDownloader: ImageDownloading, @unchecked Sendable {
    enum Mode { case success(Data); case failure(Error) }
    private let mode: Mode
    private let delayNanos: UInt64
    private let lock = NSLock()
    private(set) var calls: [URL] = []

    init(mode: Mode, delayNanos: UInt64 = 0) {
        self.mode = mode
        self.delayNanos = delayNanos
    }

    var callCount: Int { lock.lock(); defer { lock.unlock() }; return calls.count }

    func download(from url: URL, bearer: String) async throws -> Data {
        lock.lock(); calls.append(url); lock.unlock()
        if delayNanos > 0 { try? await Task.sleep(nanoseconds: delayNanos) }
        switch mode {
        case .success(let d): return d
        case .failure(let e): throw e
        }
    }
}

final class FetchedBox: @unchecked Sendable {
    private let lock = NSLock()
    private var v: [String] = []
    func append(_ s: String) { lock.lock(); v.append(s); lock.unlock() }
    var values: [String] { lock.lock(); defer { lock.unlock() }; return v }
}
