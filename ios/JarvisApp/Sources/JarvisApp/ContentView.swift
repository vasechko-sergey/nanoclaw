import SwiftUI

struct ContentView: View {
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        if settings.isConfigured {
            ChatView()
        } else {
            NavigationStack { SettingsView(isInitialSetup: true) }
        }
    }
}
