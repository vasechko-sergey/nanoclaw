import AVFoundation
import Foundation

/// Озвучка ответов агента (TTS) встроенным голосом iOS. Бесплатно, офлайн.
/// Голос выбирается в настройках; по умолчанию — лучший доступный русский.
@Observable final class SpeechSynthesizer: NSObject {
    var isSpeaking = false

    @ObservationIgnored private let synthesizer = AVSpeechSynthesizer()
    @ObservationIgnored private var categoryConfigured = false

    override init() {
        super.init()
        synthesizer.delegate = self
        // Stop speaking if the system interrupts audio (call, alarm, Siri).
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInterruption(_:)),
            name: AVAudioSession.interruptionNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func handleInterruption(_ note: Notification) {
        guard let info = note.userInfo,
              let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw),
              type == .began else { return }
        stop()
    }

    // Fixed TTS defaults — voice is now rendered server-side; on-device TTS is
    // a fallback only. Rate and pitch match the former user-facing defaults.
    private static let defaultRate: Float  = 0.47
    private static let defaultPitch: Float = 0.93

    func speak(_ rawText: String) {
        let text = Self.clean(rawText)
        guard !text.isEmpty else { return }

        configureSession()
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }

        let utterance = AVSpeechUtterance(string: text)
        // Pick the highest-quality available Russian voice; fall back to the
        // system Russian locale if none are installed.
        utterance.voice = Self.russianVoices().first
            ?? AVSpeechSynthesisVoice(language: "ru-RU")
        utterance.rate = Self.defaultRate
        utterance.pitchMultiplier = Self.defaultPitch
        utterance.volume = 1.0
        synthesizer.speak(utterance)
    }

    /// Голоса для русского, отсортированы: Enhanced/Premium качество выше дефолтного.
    static func russianVoices() -> [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("ru") }
            .sorted { $0.quality.rawValue > $1.quality.rawValue }
    }

    func stop() {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        // Release the .duckOthers session even on an interrupted / not-speaking
        // stop — the didCancel/didFinish delegate callbacks may not fire.
        deactivateSession()
    }

    private func configureSession() {
        let session = AVAudioSession.sharedInstance()
        // Set the category once — it's a relatively heavy call; no need to repeat
        // it on every utterance.
        if !categoryConfigured {
            try? session.setCategory(.playback, mode: .spokenAudio, options: .duckOthers)
            categoryConfigured = true
        }
        try? session.setActive(true, options: [])
    }

    /// Release the audio session so we stop ducking other apps once we're done.
    private func deactivateSession() {
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    /// Убирает markdown-разметку, чтобы голос не зачитывал символы.
    private static func clean(_ s: String) -> String {
        var t = s
        t = t.replacingOccurrences(of: #"```[\s\S]*?```"#, with: " код ", options: .regularExpression)
        t = t.replacingOccurrences(of: #"`([^`]*)`"#, with: "$1", options: .regularExpression)
        t = t.replacingOccurrences(of: #"!?\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        t = t.replacingOccurrences(of: #"[*_#>~]"#, with: "", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension SpeechSynthesizer: AVSpeechSynthesizerDelegate {
    func speechSynthesizer(_ s: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { self.isSpeaking = true }
    }
    func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { self.isSpeaking = false }
        deactivateSession()
    }
    func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { self.isSpeaking = false }
        deactivateSession()
    }
}
