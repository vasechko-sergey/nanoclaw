import SwiftUI

@main
struct JarvisWatchApp: App {
    @State private var state = WatchAppState()

    var body: some Scene {
        WindowGroup {
            WatchContentView()
                .environment(state)
        }
    }
}
