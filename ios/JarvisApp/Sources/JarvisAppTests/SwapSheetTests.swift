import XCTest
@testable import Jarvis

final class SwapSheetTests: XCTestCase {

    func test_swapResponse_equatable() {
        let a = SwapResponse(accepted: .init(slug: "x"), rejected: nil, alternatives: [])
        let b = SwapResponse(accepted: .init(slug: "x"), rejected: nil, alternatives: [])
        XCTAssertEqual(a, b)
    }

    func test_alternative_isIdentifiableBySlug() {
        let alt = SwapResponse.Alternative(slug: "flat-db-press", why: "no incline")
        XCTAssertEqual(alt.id, "flat-db-press")
    }

    func test_swapAction_caseEquality() {
        // Sanity that the enum cases distinguish.
        let a: SwapAction = .requestSuggestions
        let b: SwapAction = .confirm(newSlug: "x", persist: true)
        if case .requestSuggestions = a {} else { XCTFail() }
        if case let .confirm(slug, persist) = b {
            XCTAssertEqual(slug, "x"); XCTAssertTrue(persist)
        } else { XCTFail() }
    }
}
