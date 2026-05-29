import SwiftUI
import WatchKit

struct WatchContentView: View {
    @Environment(WatchAppState.self) var state

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
                        }
                        .padding(.horizontal, 6)
                    }
                    .onChange(of: state.messages.last?.id) {
                        if let last = state.messages.last {
                            withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                        }
                    }
                }

                Button(action: presentDictation) {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(WatchTheme.accent)
                        .padding(10)
                        .background(Circle().fill(WatchTheme.surface))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Голосовое сообщение")
                .padding(.bottom, 4)
            }
        }
    }

    private func presentDictation() {
        WKApplication.shared().visibleInterfaceController?.presentTextInputController(
            withSuggestions: nil,
            allowedInputMode: .plain
        ) { results in
            guard let first = results?.first as? String, !first.isEmpty else { return }
            Task { @MainActor in
                state.sendDictatedTextToPhone(first)
            }
        }
    }
}
