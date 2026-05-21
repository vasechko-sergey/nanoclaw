import SwiftUI

struct ProfileView: View {
    @EnvironmentObject var settings: AppSettings
    @ObservedObject var store: ConversationStore
    let isConnected: Bool
    var onReconnect: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss

    private var totalMessages: Int {
        store.conversations.reduce(0) { $0 + $1.messageCount }
    }

    private var memberSince: String {
        guard let oldest = store.conversations.map(\.createdAt).min() else {
            return "сегодня"
        }
        let days = Calendar.current.dateComponents([.day], from: oldest, to: Date()).day ?? 0
        if days == 0 { return "сегодня" }
        if days == 1 { return "вчера" }
        return "\(days) дн. назад"
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: Theme.fontBody))
                        .foregroundStyle(Theme.accent.opacity(0.5))
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

            ScrollView {
                VStack(spacing: Theme.scaled(28)) {
                    // Orb + name + status
                    VStack(spacing: Theme.scaled(16)) {
                        OrbView(size: Theme.scaled(100), brightness: isConnected ? 1.0 : 0.3)

                        VStack(spacing: Theme.scaled(4)) {
                            Text(settings.agentName.isEmpty ? "Jarvis" : settings.agentName)
                                .font(.system(size: Theme.scaled(22), weight: .medium))
                                .foregroundStyle(Theme.textPrimary.opacity(0.9))

                            HStack(spacing: Theme.scaled(6)) {
                                Circle()
                                    .fill(isConnected ? Theme.online : Theme.offline)
                                    .frame(width: Theme.scaled(7), height: Theme.scaled(7))
                                Text(isConnected ? "Онлайн" : "Офлайн")
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
                                    Text(isConnected ? "Переподключиться" : "Подключиться")
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

                        // Emoji status
                        if !settings.statusEmoji.isEmpty {
                            Text(settings.statusEmoji)
                                .font(.system(size: Theme.scaled(28)))
                                .padding(Theme.scaled(8))
                                .background(Theme.accent.opacity(0.06))
                                .clipShape(Circle())
                        }
                    }
                    .padding(.top, Theme.scaled(20))

                    // Stats grid
                    HStack(spacing: Theme.scaled(12)) {
                        statCard(
                            value: "\(store.conversations.count)",
                            label: "Диалогов",
                            icon: "bubble.left.and.bubble.right"
                        )
                        statCard(
                            value: "\(totalMessages)",
                            label: "Сообщений",
                            icon: "text.bubble"
                        )
                        statCard(
                            value: memberSince,
                            label: "Первый чат",
                            icon: "calendar"
                        )
                    }
                    .padding(.horizontal, Theme.hPadding)

                    // Connection info
                    VStack(alignment: .leading, spacing: 0) {
                        Text("ПОДКЛЮЧЕНИЕ")
                            .font(.system(size: Theme.fontSmall, weight: .medium))
                            .tracking(1)
                            .foregroundStyle(Theme.accent.opacity(0.3))
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
        .background(Theme.background.ignoresSafeArea())
        .preferredColorScheme(.dark)
    }

    // MARK: – Components

    private func statCard(value: String, label: String, icon: String) -> some View {
        VStack(spacing: Theme.scaled(6)) {
            Image(systemName: icon)
                .font(.system(size: Theme.fontCaption))
                .foregroundStyle(Theme.accent.opacity(0.4))

            Text(value)
                .font(.system(size: Theme.fontBody, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.textPrimary.opacity(0.8))
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            Text(label)
                .font(.system(size: Theme.fontSmall))
                .foregroundStyle(Theme.accent.opacity(0.3))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.scaled(14))
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardRadius)
                .stroke(Theme.surfaceBorder, lineWidth: 0.5)
        )
    }

    private func infoRow(icon: String, label: String, value: String) -> some View {
        HStack(spacing: Theme.scaled(10)) {
            Image(systemName: icon)
                .font(.system(size: Theme.fontCaption))
                .foregroundStyle(Theme.accent.opacity(0.4))
                .frame(width: Theme.scaled(20))
            Text(label)
                .font(.system(size: Theme.fontSubhead))
                .foregroundStyle(Theme.textSecondary)
            Spacer()
            Text(value)
                .font(.system(size: Theme.fontCaption, design: .monospaced))
                .foregroundStyle(Theme.accent.opacity(0.4))
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
