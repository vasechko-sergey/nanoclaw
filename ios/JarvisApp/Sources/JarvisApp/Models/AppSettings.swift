import SwiftUI

@Observable
final class AppSettings {
    // @AppStorage properties need @ObservationIgnored because @AppStorage
    // handles its own SwiftUI observation; @Observable auto-tracking would conflict.
    /// Fixed server endpoint — baked in, not user-editable (see ServerConfig).
    var serverURL: String { ServerConfig.url }
    @ObservationIgnored @AppStorage("bearerToken")   var bearerToken  = ""
    @ObservationIgnored @AppStorage("agentName")     var agentName    = "Jarvis"
    @ObservationIgnored @AppStorage("useLocation")   var useLocation  = false
    @ObservationIgnored @AppStorage("useHealth")     var useHealth    = false
    @ObservationIgnored @AppStorage("useCalendar")   var useCalendar  = false
    @ObservationIgnored @AppStorage("statusEmoji")   var statusEmoji  = ""
    @ObservationIgnored @AppStorage("enterToSend")   var enterToSend  = true
    @ObservationIgnored @AppStorage("autoSpeak")     var autoSpeak    = false

    // MARK: – Voice-fullscreen ("Glass") mode
    /// After TTS finishes reading the assistant reply, auto-resume the
    /// listening loop instead of waiting for the user to tap the orb.
    @ObservationIgnored @AppStorage("autoResumeListening") var autoResumeListening = true
    /// Push-to-talk: orb held while speaking, released to send. Default off
    /// (taps drive the auto-loop).
    @ObservationIgnored @AppStorage("pushToTalk")          var pushToTalk          = false
    /// Silence-timeout for the listening loop (seconds). Allowed: 15, 30, 60.
    @ObservationIgnored @AppStorage("silenceTimeoutSec")   var silenceTimeoutSec   = 30

    // MARK: – Proactive triggers (all opt-in, default off)
    @ObservationIgnored @AppStorage("proactiveGeofence")        var proactiveGeofence        = false
    @ObservationIgnored @AppStorage("proactiveHealthHR")        var proactiveHealthHR        = false
    @ObservationIgnored @AppStorage("proactiveHealthSleep")     var proactiveHealthSleep     = false
    @ObservationIgnored @AppStorage("proactiveHealthWorkout")   var proactiveHealthWorkout   = false
    @ObservationIgnored @AppStorage("proactiveCalendarWarn")    var proactiveCalendarWarn    = false

    // MARK: – Watch companion
    @ObservationIgnored @AppStorage("watchCompanionEnabled") var watchCompanionEnabled = true

    /// Whether a given trigger type is allowed to fire. Used by ProactiveDispatcher.fire.
    func proactiveEnabled(_ triggerType: String) -> Bool {
        switch triggerType {
        case "geofence":              return proactiveGeofence
        case "health_hr_spike":       return proactiveHealthHR
        case "health_sleep_end":      return proactiveHealthSleep
        case "health_workout_end":    return proactiveHealthWorkout
        case "calendar_warn":         return proactiveCalendarWarn
        default:                      return false
        }
    }

    var platformId: String {
        if let v = UserDefaults.standard.string(forKey: "platformId") { return v }
        let id = "ios:" + (UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString)
        UserDefaults.standard.set(id, forKey: "platformId")
        return id
    }

    var isConfigured: Bool {
        JarvisApp.isUITesting || !bearerToken.isEmpty
    }
}
