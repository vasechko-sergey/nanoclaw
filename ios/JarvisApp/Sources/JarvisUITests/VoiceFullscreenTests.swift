import XCTest

final class VoiceFullscreenTests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["--uitesting"]
        app.launch()
        return app
    }

    /// Tap the central home orb. OrbView's `.onTapGesture` is not always
    /// reliably reachable from XCUITest under the current view hierarchy
    /// (root `orb-home` identifier propagates down, TimelineView confuses
    /// hit-test discovery). The app installs a UI-test-only Button overlay
    /// labelled `uitest-home-orb` that calls the same `showVoiceFullscreen`
    /// path — we drive that here. Falls back to the production label
    /// `Начать диалог` if the test-only overlay is absent (smoke check).
    private func tapHomeOrb(_ app: XCUIApplication) {
        let uitestBtn = app.buttons.matching(
            NSPredicate(format: "label == 'uitest-home-orb'")
        ).firstMatch
        if uitestBtn.waitForExistence(timeout: 8) {
            uitestBtn.tap()
            return
        }
        let labelled = app.otherElements.matching(
            NSPredicate(format: "label == 'Начать диалог'")
        ).firstMatch
        XCTAssertTrue(labelled.waitForExistence(timeout: 3),
                      "Home orb should be reachable on launch")
        labelled.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }

    /// The OrbVoiceView's root `.accessibilityIdentifier("orb-voice-view")`
    /// propagates down to every descendant under SwiftUI propagation rules,
    /// just like `chat-view` does on ChatView. The "к чату" handoff Button is
    /// a stable, voice-only landmark — its label only appears once the voice
    /// view is presented.
    private func voiceViewLandmark(_ app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label == 'к чату'")).firstMatch
    }

    /// The xmark close button — labelled by SwiftUI as "Close" (system image
    /// `xmark.circle.fill`). Identifier `voice-close-btn` is shadowed by the
    /// root `orb-voice-view` identifier, so use the label.
    private func voiceCloseButton(_ app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label == 'Close'")).firstMatch
    }

    func testHomeOrbTapPresentsVoiceFullscreen() {
        let app = launchApp()
        tapHomeOrb(app)

        let landmark = voiceViewLandmark(app)
        XCTAssertTrue(landmark.waitForExistence(timeout: 3),
                      "Tapping the home center orb must open Glass mode fullscreen")
    }

    func testCloseButtonDismissesVoiceFullscreen() {
        let app = launchApp()
        tapHomeOrb(app)

        let landmark = voiceViewLandmark(app)
        XCTAssertTrue(landmark.waitForExistence(timeout: 3))

        let closeBtn = voiceCloseButton(app)
        XCTAssertTrue(closeBtn.waitForExistence(timeout: 2))
        closeBtn.tap()

        // Wait for the voice view's "к чату" landmark to disappear, signalling
        // the fullscreen cover dismissed.
        let gone = NSPredicate(format: "exists == false")
        let expectation = XCTNSPredicateExpectation(predicate: gone, object: landmark)
        XCTAssertEqual(XCTWaiter().wait(for: [expectation], timeout: 3), .completed,
                       "Voice fullscreen must dismiss after tapping the close button")
    }
}
