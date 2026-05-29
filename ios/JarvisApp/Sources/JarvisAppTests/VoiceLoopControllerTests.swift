import XCTest
@testable import Jarvis

@MainActor
final class VoiceLoopControllerTests: XCTestCase {

    func testInitialPhaseIsCalm() {
        let c = VoiceLoopController()
        XCTAssertEqual(c.phase, .calm)
        XCTAssertEqual(c.transcript, "")
    }

    func testStartTransitionsToListening() {
        let c = VoiceLoopController()
        c.start()
        XCTAssertEqual(c.phase, .listening)
    }

    func testHandleFinalTranscriptTransitionsToProcessing() {
        let c = VoiceLoopController()
        c.start()
        c.handleTranscript("привет", isFinal: true)
        XCTAssertEqual(c.phase, .processing)
        XCTAssertEqual(c.transcript, "привет")
    }

    func testHandlePartialTranscriptStaysListening() {
        let c = VoiceLoopController()
        c.start()
        c.handleTranscript("прив", isFinal: false)
        XCTAssertEqual(c.phase, .listening)
        XCTAssertEqual(c.transcript, "прив")
    }

    func testHandleAssistantArrivalTransitionsToSpeaking() {
        let c = VoiceLoopController()
        c.start()
        c.handleTranscript("привет", isFinal: true)
        c.handleAssistantTextArrived("здравствуйте")
        XCTAssertEqual(c.phase, .speaking)
    }

    func testStopTransitionsToCalm() {
        let c = VoiceLoopController()
        c.start()
        c.stop()
        XCTAssertEqual(c.phase, .calm)
    }

    func testErrorTransitionsToError() {
        let c = VoiceLoopController()
        c.start()
        c.handleError(.sttUnavailable)
        XCTAssertEqual(c.phase, .error)
    }

    func testSilenceTimeoutTransitionsToCalmWhenNoPartial() {
        let c = VoiceLoopController()
        c.start()
        c.tickSilenceTimerForTesting(elapsed: 31, threshold: 30)
        XCTAssertEqual(c.phase, .calm, "no partial in window → return to calm")
    }

    func testSilenceTimeoutDoesNothingIfPartialReceived() {
        let c = VoiceLoopController()
        c.start()
        c.handleTranscript("прив", isFinal: false)
        c.tickSilenceTimerForTesting(elapsed: 31, threshold: 30)
        XCTAssertEqual(c.phase, .listening, "partial within window keeps us listening")
    }

    func testSilenceTimeoutOnlyAppliesWhenListening() {
        let c = VoiceLoopController()
        c.start()
        c.handleTranscript("привет", isFinal: true)
        c.tickSilenceTimerForTesting(elapsed: 999, threshold: 30)
        XCTAssertEqual(c.phase, .processing, "silence timeout ignored when not listening")
    }
}
