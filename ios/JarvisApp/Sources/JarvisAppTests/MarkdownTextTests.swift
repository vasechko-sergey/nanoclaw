import XCTest
@testable import Jarvis

final class MarkdownTextTests: XCTestCase {

    func test_attributedInline_parsesInlineMarkdown() {
        let attr = MarkdownText.attributedInline("**bold** text")
        XCTAssertNotNil(attr)
        let plain = String(attr!.characters)
        XCTAssertTrue(plain.contains("bold"))
        XCTAssertFalse(plain.contains("**"), "inline markdown syntax should be parsed away")
    }

    /// The freeze fix: the same cell/inline string must be parsed at most once,
    /// regardless of how many body / Grid-measurement passes re-render it.
    func test_attributedInline_memoizesRepeatParses() {
        let unique = "memo-\(UUID().uuidString) **x**"
        let before = MarkdownText.attributedParseMisses
        _ = MarkdownText.attributedInline(unique)
        _ = MarkdownText.attributedInline(unique)
        _ = MarkdownText.attributedInline(unique)
        XCTAssertEqual(MarkdownText.attributedParseMisses - before, 1,
                       "repeat parses of the same string must hit the cache (one real parse)")
    }

    /// Startup prewarm must populate the inline cache for paragraph + table-cell
    /// strings, so the first real render of that message is all cache hits.
    func test_prewarm_warmsParagraphAndTableCells() {
        let u = UUID().uuidString
        let md = """
        para \(u) **x**

        | h-\(u) | b |
        |---|---|
        | c-\(u) | d |
        """
        MarkdownText.prewarm(md)
        let afterPrewarm = MarkdownText.attributedParseMisses

        // Rendering the same paragraph + a table cell must NOT add new parses.
        _ = MarkdownText.attributedInline("para \(u) **x**")
        _ = MarkdownText.attributedInline("c-\(u)")
        XCTAssertEqual(MarkdownText.attributedParseMisses, afterPrewarm,
                       "post-prewarm renders of warmed strings must be cache hits")
    }
}
