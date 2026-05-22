import SwiftUI

final class AppSettings: ObservableObject {
    @AppStorage("serverURL")     var serverURL    = ""
    @AppStorage("bearerToken")   var bearerToken  = ""
    @AppStorage("agentName")     var agentName    = "Jarvis"
    @AppStorage("useLocation")   var useLocation  = false
    @AppStorage("useHealth")     var useHealth    = false
    @AppStorage("useCalendar")   var useCalendar  = false
    @AppStorage("statusEmoji")   var statusEmoji  = ""
    @AppStorage("enterToSend")   var enterToSend  = true
    @AppStorage("inputMode")     var inputMode    = "classic"   // "classic" | "orb"
    @AppStorage("orbPrimary")    var orbPrimary   = "voice"     // "voice" | "text" — tap-on-orb action
    @AppStorage("autoSpeak")     var autoSpeak    = false
    @AppStorage("voiceId")       var voiceId      = ""
    @AppStorage("voiceRate")     var voiceRate    = 0.47
    @AppStorage("voicePitch")    var voicePitch   = 0.93

    var platformId: String {
        if let v = UserDefaults.standard.string(forKey: "platformId") { return v }
        let id = "ios:" + (UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString)
        UserDefaults.standard.set(id, forKey: "platformId")
        return id
    }

    var isConfigured: Bool { !serverURL.isEmpty && !bearerToken.isEmpty }
}
