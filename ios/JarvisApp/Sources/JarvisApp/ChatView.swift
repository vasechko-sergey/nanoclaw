import SwiftUI

private let bgColor = Color(red: 0.04, green: 0.1, blue: 0.09)
private let teal = Color(red: 0, green: 0.82, blue: 0.75)

struct ChatView: View {
    @EnvironmentObject var settings: AppSettings
    @StateObject private var ws       = WebSocketClient()
    @StateObject private var location = LocationManager()
    @StateObject private var health   = HealthManager()
    @State private var inputText    = ""
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            ZStack {
                bgColor.ignoresSafeArea()
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
                        .scrollContentBackground(.hidden)
                        .onChange(of: ws.messages.count) { _ in
                            if let last = ws.messages.last {
                                withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                            }
                        }
                        .onChange(of: ws.isTyping) { t in
                            if t { withAnimation { proxy.scrollTo("typing", anchor: .bottom) } }
                        }
                    }

                    Divider().background(teal.opacity(0.3))

                    InputBar(text: $inputText) {
                        let trimmed = inputText.trimmingCharacters(in: .whitespaces)
                        guard !trimmed.isEmpty else { return }
                        let ctx = ContextBuilder.build(settings: settings, location: location, health: health)
                        ws.send(text: trimmed, context: ctx)
                        inputText = ""
                    }
                }
            }
            .navigationTitle(settings.agentName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color(red: 0.04, green: 0.1, blue: 0.09), for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Circle()
                        .fill(ws.isConnected ? teal : Color.red.opacity(0.8))
                        .frame(width: 8, height: 8)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: {
                        Image(systemName: "gearshape")
                            .foregroundStyle(teal)
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
