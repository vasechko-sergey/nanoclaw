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

    // MARK: - fittedSize (image sizing into the proposed 16:9 hero)

    /// A tall PORTRAIT image must take the proposed 16:9 box, not its own height —
    /// the runner has no scroll view, so an oversized image shoved the set-logging
    /// card + toolbar off-screen (отведение-на-дельту, the only portrait asset).
    func test_fittedSize_portraitImage_takesProposedBox_notIntrinsicHeight() {
        let s = ExerciseImageFormat.fittedSize(
            proposalWidth: 390, proposalHeight: 219,
            intrinsic: CGSize(width: 300, height: 900))
        XCTAssertEqual(s, CGSize(width: 390, height: 219))
    }

    /// An unspecified dimension (nil proposal) falls back to the image's own size.
    func test_fittedSize_unspecified_fallsBackToIntrinsic() {
        let s = ExerciseImageFormat.fittedSize(
            proposalWidth: nil, proposalHeight: nil,
            intrinsic: CGSize(width: 300, height: 900))
        XCTAssertEqual(s, CGSize(width: 300, height: 900))
    }

    /// An infinite proposal (e.g. an unbounded ScrollView axis) also falls back,
    /// so the image never tries to paint at infinite size.
    func test_fittedSize_infinite_fallsBackToIntrinsic() {
        let s = ExerciseImageFormat.fittedSize(
            proposalWidth: .infinity, proposalHeight: 219,
            intrinsic: CGSize(width: 300, height: 900))
        XCTAssertEqual(s.width, 300)
        XCTAssertEqual(s.height, 219)
    }
}
