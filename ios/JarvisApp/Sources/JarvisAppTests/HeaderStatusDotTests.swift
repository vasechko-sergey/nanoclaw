import XCTest
import SwiftUI
@testable import Jarvis

@MainActor
final class HeaderStatusDotTests: XCTestCase {

    func testLeftFillOnlineWhenConnected() {
        let dot = HeaderStatusDot(side: .left, isConnected: true, phase: .calm) {}
        XCTAssertEqual(dot.resolvedFillColor, Theme.online)
    }

    func testLeftFillOfflineWhenDisconnected() {
        let dot = HeaderStatusDot(side: .left, isConnected: false, phase: .calm) {}
        XCTAssertEqual(dot.resolvedFillColor, Theme.offline)
    }

    func testRightFillAccentWhenProcessing() {
        let dot = HeaderStatusDot(side: .right, isConnected: true, phase: .processing) {}
        XCTAssertEqual(dot.resolvedFillColor, Theme.accent)
    }

    func testRightFillAccentWhenListening() {
        let dot = HeaderStatusDot(side: .right, isConnected: true, phase: .listening) {}
        XCTAssertEqual(dot.resolvedFillColor, Theme.accent)
    }

    func testRightFillAccentWhenSpeaking() {
        let dot = HeaderStatusDot(side: .right, isConnected: true, phase: .speaking) {}
        XCTAssertEqual(dot.resolvedFillColor, Theme.accent)
    }

    func testRightFillOfflineWhenError() {
        let dot = HeaderStatusDot(side: .right, isConnected: true, phase: .error) {}
        XCTAssertEqual(dot.resolvedFillColor, Theme.offline)
    }

    func testRightFillAccentMediumForOtherMoods() {
        let dot = HeaderStatusDot(side: .right, isConnected: true, phase: .calm) {}
        XCTAssertEqual(dot.resolvedFillColor, Theme.accentMedium)
    }
}
