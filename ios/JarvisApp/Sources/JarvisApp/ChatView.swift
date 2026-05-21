import SwiftUI
import UIKit

private let bgColor = Color(red: 0.07, green: 0.11, blue: 0.15)
private let teal = Color(red: 0.33, green: 0.74, blue: 0.77)

private struct IdentifiableImage: Identifiable {
    let id = UUID()
    let image: UIImage
}

struct ChatView: View {
    @EnvironmentObject var settings: AppSettings
    @StateObject private var ws       = WebSocketClient()
    @StateObject private var location = LocationManager()
    @StateObject private var health   = HealthManager()
    @State private var inputText      = ""
    @State private var showSettings   = false
    @State private var showEmojiPicker = false
    @State private var fullScreenImage: UIImage? = nil

    var body: some View {
        NavigationStack {
            ZStack {
                bgColor.ignoresSafeArea()
                VStack(spacing: 0) {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 8) {
                                ForEach(ws.messages) { msg in
                                    MessageBubble(message: msg) { img in
                                        fullScreenImage = img
                                    }.id(msg.id)
                                }
                                if ws.isTyping { TypingIndicator().id("typing") }
                            }
                            .padding(.horizontal)
                            .padding(.top, 8)
                        }
                        .scrollContentBackground(.hidden)
                        .onAppear {
                            if let last = ws.messages.last {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            }
                        }
                        .onChange(of: ws.messages.count) {
                            if let last = ws.messages.last {
                                withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                            }
                        }
                        .onChange(of: ws.isTyping) {
                            if ws.isTyping { withAnimation { proxy.scrollTo("typing", anchor: .bottom) } }
                        }
                        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                                if ws.isTyping {
                                    withAnimation { proxy.scrollTo("typing", anchor: .bottom) }
                                } else if let last = ws.messages.last {
                                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                                }
                            }
                        }
                    }

                    Divider().background(teal.opacity(0.3))

                    InputBar(text: $inputText, commands: ws.commands) {
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
            .toolbarBackground(Color(red: 0.07, green: 0.11, blue: 0.15), for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Circle()
                        .fill(ws.isConnected ? teal : Color.red.opacity(0.8))
                        .frame(width: 8, height: 8)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 4) {
                        Button {
                            showEmojiPicker.toggle()
                        } label: {
                            Text(settings.statusEmoji.isEmpty ? "🙂" : settings.statusEmoji)
                                .font(.system(size: 20))
                                .opacity(settings.statusEmoji.isEmpty ? 0.35 : 1)
                        }
                        .popover(isPresented: $showEmojiPicker) {
                            EmojiPickerView(selected: $settings.statusEmoji)
                                .presentationCompactAdaptation(.popover)
                        }
                        Button { showSettings = true } label: {
                            Image(systemName: "gearshape")
                                .foregroundStyle(teal)
                        }
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                NavigationStack { SettingsView(isInitialSetup: false) }
            }
            .fullScreenCover(item: Binding(
                get: { fullScreenImage.map { IdentifiableImage(image: $0) } },
                set: { fullScreenImage = $0?.image }
            )) { item in
                FullScreenImageView(image: item.image)
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
