import SwiftUI

struct ChatView: View {
    @EnvironmentObject var settings: AppSettings
    @StateObject private var ws       = WebSocketClient()
    @StateObject private var location = LocationManager()
    @StateObject private var health   = HealthManager()
    @State private var inputText    = ""
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(ws.messages) { msg in
                                MessageBubble(message: msg).id(msg.id)
                            }
                            if ws.isTyping { TypingIndicator().id("typing") }
                        }
                        .padding(.horizontal)
                        .padding(.top, 8)
                    }
                    .onChange(of: ws.messages.count) { _ in
                        if let last = ws.messages.last {
                            withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                        }
                    }
                    .onChange(of: ws.isTyping) { t in
                        if t { withAnimation { proxy.scrollTo("typing", anchor: .bottom) } }
                    }
                }

                Divider()

                InputBar(text: $inputText) {
                    let trimmed = inputText.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.isEmpty else { return }
                    let ctx = ContextBuilder.build(settings: settings, location: location, health: health)
                    ws.send(text: trimmed, context: ctx)
                    inputText = ""
                }
            }
            .navigationTitle(settings.agentName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Circle()
                        .fill(ws.isConnected ? Color.green : Color.red)
                        .frame(width: 8, height: 8)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                NavigationStack { SettingsView(isInitialSetup: false) }
            }
        }
        .onAppear {
            ws.connect(settings: settings)
            if settings.useLocation { location.requestAndUpdate() }
            if settings.useHealth   { health.requestAndFetch()    }
        }
        .onDisappear { ws.disconnect() }
    }
}
