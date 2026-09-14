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
        let b: SwapAction = .confirm(newSlug: "x", persist: true, nameRu: "Жим", sha256: "sha")
        if case .requestSuggestions = a {} else { XCTFail() }
        if case let .confirm(slug, persist, nameRu, sha) = b {
            XCTAssertEqual(slug, "x"); XCTAssertTrue(persist)
            XCTAssertEqual(nameRu, "Жим"); XCTAssertEqual(sha, "sha")
        } else { XCTFail() }
    }

    /// The sheet must never show a raw slug when Payne sent a name — that was
    /// the visible half of the broken swap ("Заменить на «Zhim ganteley sidya»").
    func test_alternative_displayName_prefersRussianName() {
        let named = SwapResponse.Alternative(slug: "zhim-ganteley-sidya", why: "плечо",
                                             nameRu: "Жим гантелей сидя")
        XCTAssertEqual(named.displayName, "Жим гантелей сидя")
        // Older server / own-proposal path → prettified slug, not the raw one.
        let bare = SwapResponse.Alternative(slug: "zhim-ganteley-sidya", why: "плечо")
        XCTAssertEqual(bare.displayName, "Zhim ganteley sidya")
    }
}
