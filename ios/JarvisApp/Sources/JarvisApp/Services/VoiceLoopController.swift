import Foundation

/// Drives the voice-fullscreen ("Glass") loop. Owns the phase state machine,
/// the current partial transcript, and the integration callbacks. STT/TTS
/// services are owned by the presenting view; the controller stays pure so
/// it can be unit-tested without a microphone or audio session.
@Observable @MainActor final class VoiceLoopController {

    enum Phase: Equatable {
        case calm
        case listening
        case processing
        case speaking
        case error
    }

    enum VoiceError: Equatable {
        case sttUnavailable
        case micDenied
        case unknown
    }

    private(set) var phase: Phase = .calm
    private(set) var transcript: String = ""
    private(set) var lastError: VoiceError? = nil
    private(set) var lastPartialAt: Date?

    /// Begin a listening session.
    func start() {
        transcript = ""
        lastError = nil
        phase = .listening
        lastPartialAt = nil
    }

    /// Fully stop the loop (X tap).
    func stop() {
        phase = .calm
    }

    /// `isFinal == true` transitions to .processing; partials only update transcript.
    func handleTranscript(_ text: String, isFinal: Bool) {
        lastPartialAt = Date()
        transcript = text
        if isFinal {
            phase = .processing
        }
    }

    /// Assistant reply arrived — orb mood updates; the view kicks off TTS.
    func handleAssistantTextArrived(_ text: String) {
        phase = .speaking
    }

    /// Forwarded by the view from SpeechSynthesizerDelegate.didFinish.
    /// `autoResume == true` → back to .listening; else park on .calm.
    func handleSynthesizerDidFinish(autoResume: Bool) {
        if autoResume {
            transcript = ""
            phase = .listening
        } else {
            phase = .calm
        }
    }

    /// STT or mic permission failure.
    func handleError(_ err: VoiceError) {
        lastError = err
        phase = .error
    }

    /// Production seam — view runs a 1Hz timer calling this with
    /// `elapsed = now - lastPartialAt` and `threshold = settings.silenceTimeoutSec`.
    /// In `.listening` only, over-threshold silence parks the loop on `.calm`.
    /// A fresh `lastPartialAt` (set by `handleTranscript`) resets the clock.
    func tickSilence(elapsed: TimeInterval, threshold: TimeInterval) {
        guard phase == .listening else { return }
        // Cross-check against our own clock: if a partial arrived more recently
        // than `elapsed` ago, we are not actually silent.
        if let last = lastPartialAt {
            let actual = Date().timeIntervalSince(last)
            if actual <= threshold { return }
        }
        if elapsed > threshold {
            phase = .calm
        }
    }

    /// Test seam.
    func tickSilenceTimerForTesting(elapsed: TimeInterval, threshold: TimeInterval) {
        tickSilence(elapsed: elapsed, threshold: threshold)
    }
}
