import Foundation

/// Lightweight controller for the Node `e2e-harness` process (see
/// `scripts/e2e-harness.ts` + `pnpm run e2e:harness`).
///
/// Important constraint: the iOS Foundation does **not** expose `Process` —
/// process spawning is a macOS-only API. The unit-test bundle runs on the
/// iOS Simulator, so `start()` is a no-op there and the operator must launch
/// the harness externally before invoking `xcodebuild test`:
///
///     E2E_PORT=8801 E2E_SCENARIO=happy pnpm run e2e:harness &
///     xcodebuild test -only-testing:JarvisAppTests/HappyPathE2ETests ...
///
/// On macOS host environments (e.g. SwiftPM `swift test`) the harness can
/// be auto-spawned. `isHarnessReachable(port:)` lets tests probe before
/// running so they can skip cleanly when the operator forgot to start it.
final class E2EHarness {
    static let defaultPort = 8801
    static let defaultToken = "test-token"

    #if os(macOS)
    private var task: Process?
    #endif

    /// Best-effort: on macOS, spawn the harness as a child process. On iOS
    /// Simulator (where `Process` is unavailable), this is a no-op — the
    /// caller is expected to have started the harness out-of-band.
    func start(scenario: String, port: Int = E2EHarness.defaultPort) throws {
        #if os(macOS)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = [
            "-lc",
            "cd \(repoRoot()) && E2E_PORT=\(port) E2E_SCENARIO=\(scenario) pnpm run e2e:harness",
        ]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        task = p
        // Give it time to bind. The harness logs to stderr on listen.
        Thread.sleep(forTimeInterval: 1.0)
        #else
        // iOS Simulator: rely on externally-started harness.
        _ = scenario
        _ = port
        #endif
    }

    func stop() {
        #if os(macOS)
        task?.terminate()
        task = nil
        #endif
    }

    /// Probes `ws://127.0.0.1:<port>` by opening a TCP socket. Useful as a
    /// precondition check in `setUp` so tests `XCTSkip` cleanly when the
    /// operator forgot to start the harness.
    static func isHarnessReachable(port: Int = E2EHarness.defaultPort, timeoutSeconds: Double = 0.5) -> Bool {
        var hints = addrinfo(
            ai_flags: 0,
            ai_family: AF_INET,
            ai_socktype: SOCK_STREAM,
            ai_protocol: IPPROTO_TCP,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )
        var res: UnsafeMutablePointer<addrinfo>?
        let rc = getaddrinfo("127.0.0.1", String(port), &hints, &res)
        guard rc == 0, let info = res else { return false }
        defer { freeaddrinfo(info) }

        let sock = socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
        guard sock >= 0 else { return false }
        defer { close(sock) }

        // Non-blocking connect with timeout.
        let flags = fcntl(sock, F_GETFL, 0)
        _ = fcntl(sock, F_SETFL, flags | O_NONBLOCK)
        let result = connect(sock, info.pointee.ai_addr, info.pointee.ai_addrlen)
        if result == 0 { return true }
        if errno != EINPROGRESS { return false }

        var pfd = pollfd(fd: sock, events: Int16(POLLOUT), revents: 0)
        let pollRC = withUnsafeMutablePointer(to: &pfd) { ptr in
            poll(ptr, 1, Int32(timeoutSeconds * 1000))
        }
        guard pollRC > 0 else { return false }
        var soError: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        let getoptRC = getsockopt(sock, SOL_SOCKET, SO_ERROR, &soError, &len)
        return getoptRC == 0 && soError == 0
    }

    #if os(macOS)
    private func repoRoot() -> String {
        // E2EHarness.swift lives at
        //   ios/JarvisApp/Sources/JarvisAppTests/E2E/E2EHarness.swift
        // → 5 levels up = repo root.
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // E2E/
            .deletingLastPathComponent()  // JarvisAppTests/
            .deletingLastPathComponent()  // Sources/
            .deletingLastPathComponent()  // JarvisApp/
            .deletingLastPathComponent()  // ios/
            .path
    }
    #endif
}
