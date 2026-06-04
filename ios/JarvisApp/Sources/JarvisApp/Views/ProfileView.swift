import SwiftUI

/// Embeddable profile body — used by both `ProfileView` (legacy sheet) and
/// `RightDrawerContent` (drawer in normal flow). Renders only the rows, no
/// header chrome.
struct ProfileFormBody: View {
    @Environment(AppSettings.self) var settings
    let isConnected: Bool
    var onReconnect: (() -> Void)? = nil

    @State private var showEmojiPicker = false

    var body: some View {
        @Bindable var settings = settings
        return ScrollView {
            VStack(spacing: Theme.scaled(28)) {
                // Orb + name + status
                VStack(spacing: Theme.scaled(16)) {
                    OrbView(size: Theme.scaled(100), mood: isConnected ? .calm : .error)

                    VStack(spacing: Theme.scaled(4)) {
                        Text(settings.agentName.isEmpty ? "Jarvis" : settings.agentName)
                            .font(.system(size: Theme.scaled(22), weight: .medium))
                            .foregroundStyle(Theme.textPrimary.opacity(0.9))

                        HStack(spacing: Theme.scaled(6)) {
                            Circle()
                                .fill(isConnected ? Theme.online : Theme.offline)
                                .frame(width: Theme.scaled(7), height: Theme.scaled(7))
                            Text(isConnected ? "На связи" : "Не в сети")
                                .font(.system(size: Theme.fontCaption))
                                .foregroundStyle(isConnected
                                    ? Theme.online.opacity(0.8)
                                    : Theme.offline.opacity(0.8))
                        }
                    }

                    // Reconnect button
                    if let onReconnect {
                        Button {
                            Theme.hapticSend()
                            onReconnect()
                        } label: {
                            HStack(spacing: Theme.scaled(6)) {
                                Image(systemName: isConnected ? "arrow.triangle.2.circlepath" : "bolt.horizontal")
                                    .font(.system(size: Theme.scaled(13)))
                                Text(isConnected ? "Переподключить" : "Подключить")
                                    .font(.system(size: Theme.fontSmall, weight: .medium))
                            }
                            .foregroundStyle(Theme.accent)
                            .padding(.horizontal, Theme.scaled(16))
                            .padding(.vertical, Theme.scaled(8))
                            .background(Theme.accent.opacity(0.1))
                            .clipShape(Capsule())
                        }
                        .frame(minHeight: Theme.minTapSize)
                    }

                    // Emoji status (tap to change)
                    Button { showEmojiPicker.toggle() } label: {
                        Text(settings.statusEmoji.isEmpty ? "🙂" : settings.statusEmoji)
                            .font(.system(size: Theme.scaled(28)))
                            .opacity(settings.statusEmoji.isEmpty ? 0.35 : 1)
                            .padding(Theme.scaled(8))
                            .background(Theme.accent.opacity(0.06))
                            .clipShape(Circle())
                            .overlay(
                                Circle()
                                    .stroke(Theme.accentSubtle.opacity(0.3), lineWidth: 0.5)
                            )
                    }
                    .popover(isPresented: $showEmojiPicker) {
                        EmojiPickerView(selected: $settings.statusEmoji)
                            .presentationCompactAdaptation(.popover)
                    }
                    .accessibilityLabel("Статус-эмодзи")
                }
                .padding(.top, Theme.scaled(20))

                // Connection info
                VStack(alignment: .leading, spacing: 0) {
                    Text("ПОДКЛЮЧЕНИЕ")
                        .font(.system(size: Theme.fontSmall, weight: .medium))
                        .tracking(1)
                        .foregroundStyle(Theme.accentMedium)
                        .padding(.bottom, Theme.scaled(8))
                        .padding(.leading, Theme.scaled(4))

                    VStack(spacing: 0) {
                        infoRow(icon: "network", label: "Сервер",
                                value: settings.serverURL.isEmpty ? "—" : maskedURL(settings.serverURL))
                        Divider().background(Theme.accent.opacity(0.06)).padding(.leading, Theme.scaled(46))
                        infoRow(icon: "key", label: "Токен",
                                value: settings.bearerToken.isEmpty ? "—" : "••••••••")
                        Divider().background(Theme.accent.opacity(0.06)).padding(.leading, Theme.scaled(46))
                        infoRow(icon: "cpu", label: "Платформа",
                                value: String(settings.platformId.suffix(8)))
                    }
                    .background(Theme.surface)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius))
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.cardRadius)
                            .stroke(Theme.surfaceBorder, lineWidth: 0.5)
                    )
                }
                .padding(.horizontal, Theme.hPadding)
            }
            .padding(.bottom, Theme.scaled(32))
        }
    }

    // MARK: – Components

    private func infoRow(icon: String, label: String, value: String) -> some View {
        HStack(spacing: Theme.scaled(10)) {
            Image(systemName: icon)
                .font(.system(size: Theme.fontCaption))
                .foregroundStyle(Theme.accentMedium)
                .frame(width: Theme.scaled(20))
            Text(label)
                .font(.system(size: Theme.fontSubhead))
                .foregroundStyle(Theme.textSecondary)
            Spacer()
            Text(value)
                .font(.system(size: Theme.fontCaption, design: .monospaced))
                .foregroundStyle(Theme.accentMedium)
                .lineLimit(1)
        }
        .padding(.horizontal, Theme.hPadding)
        .frame(minHeight: Theme.minTapSize)
    }

    private func maskedURL(_ url: String) -> String {
        if url.count > 16 {
            return String(url.prefix(12)) + "..."
        }
        return url
    }
}

struct ProfileView: View {
    @Environment(AppSettings.self) var settings
    let isConnected: Bool
    var onReconnect: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            header
            ProfileFormBody(isConnected: isConnected, onReconnect: onReconnect)
        }
        .background(Theme.background.ignoresSafeArea())
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: Theme.fontBody))
                    .foregroundStyle(Theme.accentMedium)
                    .frame(width: Theme.minTapSize, height: Theme.minTapSize)
            }
            Spacer()
            Text("Профиль")
                .font(.system(size: Theme.fontBody, weight: .medium))
                .foregroundStyle(Theme.textPrimary.opacity(0.8))
            Spacer()
            Color.clear.frame(width: Theme.minTapSize, height: Theme.minTapSize)
        }
        .padding(.horizontal, Theme.hPadding)
        .padding(.vertical, Theme.scaled(10))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.accent.opacity(0.08)).frame(height: 0.5)
        }
    }
}
