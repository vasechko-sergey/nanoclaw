import XCTest
@testable import Jarvis

final class ExerciseImageFormatTests: XCTestCase {
    private func tmpFile(_ bytes: [UInt8], _ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)")
        try Data(bytes).write(to: url)
        return url
    }

    func test_isAnimatedGIF_trueForGIFMagic() throws {
        let url = try tmpFile([0x47, 0x49, 0x46, 0x38, 0x39, 0x61], "g.gif")  // GIF89a
        XCTAssertTrue(ExerciseImageFormat.isAnimatedGIF(at: url))
    }

    func test_isAnimatedGIF_falseForJPEG() throws {
        let url = try tmpFile([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10], "j.jpg")  // JPEG SOI
        XCTAssertFalse(ExerciseImageFormat.isAnimatedGIF(at: url))
    }

    func test_isAnimatedGIF_falseForShortFile() throws {
        let url = try tmpFile([0x47, 0x49], "s.bin")
        XCTAssertFalse(ExerciseImageFormat.isAnimatedGIF(at: url))
    }
}
