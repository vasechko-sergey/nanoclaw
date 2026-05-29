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

    /// Begin a listening session.
    func start() {
        transcript = ""
        lastError = nil
        phase = .listening
    }

    /// Fully stop the loop (X tap).
    func stop() {
        phase = .calm
    }

    /// `isFinal == true` transitions to .processing; partials only update transcript.
    func handleTranscript(_ text: String, isFinal: Bool) {
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
}
