import XCTest
@testable import Jarvis

/// Pins the Swift V2 mirror against the canonical fixtures shared with the host
/// adapter and agent-runner. Every *.json fixture under
/// shared/ios-app-protocol/fixtures/ must decode, re-encode, and decode again
/// to a semantically-equal envelope.
final class ProtocolFixtureTests: XCTestCase {

    private func fixturesDir() throws -> URL {
        // This file lives at:
        //   ios/JarvisApp/Sources/JarvisAppTests/ProtocolFixtureTests.swift
        // The fixtures live at:
        //   shared/ios-app-protocol/fixtures/
        // Walk up five directories (file, JarvisAppTests, Sources, JarvisApp, ios)
        // to reach the repo root, then descend into shared/.
        let here = URL(fileURLWithPath: #filePath)
        return here
            .deletingLastPathComponent() // JarvisAppTests/
            .deletingLastPathComponent() // Sources/
            .deletingLastPathComponent() // JarvisApp/
            .deletingLastPathComponent() // ios/
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("shared/ios-app-protocol/fixtures")
    }

    func testAllFixturesRoundTrip() throws {
        let dir = try fixturesDir()
        let urls = try FileManager.default
            .contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        XCTAssertEqual(urls.count, 17, "envelope fixture count mismatch — expected 17, got \(urls.count) at \(dir.path)")

        let decoder = JSONDecoder()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        for url in urls {
            let data = try Data(contentsOf: url)
            let env: V2.Envelope
            do {
                env = try decoder.decode(V2.Envelope.self, from: data)
            } catch {
                XCTFail("decode failed for \(url.lastPathComponent): \(error)")
                continue
            }
            let re: Data
            do {
                re = try encoder.encode(env)
            } catch {
                XCTFail("encode failed for \(url.lastPathComponent): \(error)")
                continue
            }
            let reDecoded: V2.Envelope
            do {
                reDecoded = try decoder.decode(V2.Envelope.self, from: re)
            } catch {
                XCTFail("re-decode failed for \(url.lastPathComponent): \(error)\n  re-encoded: \(String(data: re, encoding: .utf8) ?? "<binary>")")
                continue
            }
            XCTAssertEqual(env, reDecoded, "\(url.lastPathComponent) round-trip mismatch")
        }
    }

    func testHealthUploadFixturesRoundTrip() throws {
        let dir = try fixturesDir().appendingPathComponent("health")
        let urls = try FileManager.default
            .contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        XCTAssertGreaterThan(urls.count, 0, "no health fixtures found at \(dir.path)")

        let decoder = JSONDecoder()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        for url in urls {
            let data = try Data(contentsOf: url)
            let body = try decoder.decode(V2.HealthUpload.Body.self, from: data)
            let re = try encoder.encode(body)
            let reDecoded = try decoder.decode(V2.HealthUpload.Body.self, from: re)
            XCTAssertEqual(body, reDecoded, "\(url.lastPathComponent) round-trip mismatch")
        }
    }
}
