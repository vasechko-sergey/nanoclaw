import SwiftUI

@Observable
final class AppSettings {
    // @AppStorage properties need @ObservationIgnored because @AppStorage
    // handles its own SwiftUI observation; @Observable auto-tracking would conflict.
    @ObservationIgnored @AppStorage("serverURL")     var serverURL    = ""
    @ObservationIgnored @AppStorage("bearerToken")   var bearerToken  = ""
    @ObservationIgnored @AppStorage("agentName")     var agentName    = "Jarvis"
    @ObservationIgnored @AppStorage("useLocation")   var useLocation  = false
    @ObservationIgnored @AppStorage("useHealth")     var useHealth    = false
    @ObservationIgnored @AppStorage("useCalendar")   var useCalendar  = false
    @ObservationIgnored @AppStorage("statusEmoji")   var statusEmoji  = ""
    @ObservationIgnored @AppStorage("enterToSend")   var enterToSend  = true
    @ObservationIgnored @AppStorage("autoSpeak")     var autoSpeak    = false
    @ObservationIgnored @AppStorage("voiceId")       var voiceId      = ""
    @ObservationIgnored @AppStorage("voiceRate")     var voiceRate    = 0.47
    @ObservationIgnored @AppStorage("voicePitch")    var voicePitch   = 0.93

    // MARK: – Voice-fullscreen ("Glass") mode
    /// After TTS finishes reading the assistant reply, auto-resume the
    /// listening loop instead of waiting for the user to tap the orb.
    @ObservationIgnored @AppStorage("autoResumeListening") var autoResumeListening = true
    /// Push-to-talk: orb held while speaking, released to send. Default off
    /// (taps drive the auto-loop).
    @ObservationIgnored @AppStorage("pushToTalk")          var pushToTalk          = false
    /// Silence-timeout for the listening loop (seconds). Allowed: 15, 30, 60.
    @ObservationIgnored @AppStorage("silenceTimeoutSec")   var silenceTimeoutSec   = 30

    var platformId: String {
        if let v = UserDefaults.standard.string(forKey: "platformId") { return v }
        let id = "ios:" + (UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString)
        UserDefaults.standard.set(id, forKey: "platformId")
        return id
    }

    var isConfigured: Bool {
        JarvisApp.isUITesting || (!serverURL.isEmpty && !bearerToken.isEmpty)
    }
}
