import AVFoundation
import Foundation

/// Озвучка ответов агента (TTS) встроенным голосом iOS. Бесплатно, офлайн.
/// Голос выбирается в настройках; по умолчанию — лучший доступный русский.
final class SpeechSynthesizer: NSObject, ObservableObject {
    @Published var isSpeaking = false

    private let synthesizer = AVSpeechSynthesizer()
    private var categoryConfigured = false

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

    @objc private func handleInterruption(_ note: Notification) {
        guard let info = note.userInfo,
              let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw),
              type == .began else { return }
        stop()
    }

    /// Голоса для русского, отсортированы: Enhanced/Premium качество выше дефолтного.
    static func russianVoices() -> [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("ru") }
            .sorted { $0.quality.rawValue > $1.quality.rawValue }
    }

    func speak(_ rawText: String, voiceId: String, rate: Double = 0.47, pitch: Double = 0.93) {
        let text = Self.clean(rawText)
        guard !text.isEmpty else { return }

        configureSession()
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }

        let utterance = AVSpeechUtterance(string: text)
        if !voiceId.isEmpty, let voice = AVSpeechSynthesisVoice(identifier: voiceId) {
            utterance.voice = voice
        } else {
            utterance.voice = Self.russianVoices().first
                ?? AVSpeechSynthesisVoice(language: "ru-RU")
        }
        utterance.rate = Float(rate)
        utterance.pitchMultiplier = Float(pitch)
        utterance.volume = 1.0
        synthesizer.speak(utterance)
    }

    func stop() {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
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
