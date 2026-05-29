import SwiftUI

struct WatchContentView: View {
    @Environment(WatchAppState.self) var state
    /// Injected from JarvisWatchApp — drives the mic recording lifecycle.
    var onPushToTalkStart: () -> Void = {}
    var onPushToTalkEnd: () -> Void = {}

    var body: some View {
        ZStack {
            WatchTheme.background.ignoresSafeArea()

            VStack(spacing: 4) {
                HStack(spacing: 4) {
                    Circle()
                        .fill(state.isConnectedToPhone ? WatchTheme.online : WatchTheme.offline)
                        .frame(width: 6, height: 6)
                    Text(state.isConnectedToPhone ? "iPhone" : "off")
                        .font(WatchTheme.metaFont)
                        .foregroundStyle(WatchTheme.accentMed)
                    Spacer()
                }
                .padding(.horizontal, 6)

                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(state.messages) { m in
                                Text(m.text)
                                    .font(WatchTheme.messageFont)
                                    .foregroundStyle(WatchTheme.textPrimary.opacity(0.9))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .id(m.id)
                            }
                            if state.isRecording && !state.partialTranscript.isEmpty {
                                Text(state.partialTranscript)
                                    .font(WatchTheme.messageFont)
                                    .foregroundStyle(WatchTheme.accent.opacity(0.85))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(.horizontal, 6)
                    }
                    .onChange(of: state.messages.last?.id) {
                        if let last = state.messages.last {
                            withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                        }
                    }
                }

                pttButton
                    .padding(.bottom, 4)
            }
        }
    }

    private var pttButton: some View {
        Image(systemName: state.isRecording ? "mic.fill" : "mic")
            .font(.system(size: 22, weight: .medium))
            .foregroundStyle(WatchTheme.accent)
            .padding(10)
            .background(
                Circle()
                    .fill(state.isRecording ? WatchTheme.accent.opacity(0.18) : WatchTheme.surface)
            )
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if !state.isRecording { onPushToTalkStart() }
                    }
                    .onEnded { _ in
                        if state.isRecording { onPushToTalkEnd() }
                    }
            )
            .accessibilityLabel("Удерживайте для голоса")
    }
}
