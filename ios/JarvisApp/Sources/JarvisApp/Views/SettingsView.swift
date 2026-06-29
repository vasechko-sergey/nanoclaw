import SwiftUI

/// Embeddable settings form body — used by both `SettingsView` (sheet during
/// initial setup) and `RightDrawerContent` (drawer in normal flow).
/// Renders only the rows, no header or NavigationStack chrome.
struct SettingsFormBody: View {
    var isInitialSetup: Bool = false
    @Environment(AppSettings.self) var settings

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }
    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }

    var body: some View {
        @Bindable var settings = settings
        return ScrollView {
            VStack(spacing: Theme.scaled(20)) {
                if isInitialSetup {
                    // Setup header
                    VStack(spacing: Theme.scaled(8)) {
                        MiniOrbView(size: Theme.scaled(80), mood: .calm)
                        Text("Настройка")
                            .font(.system(size: Theme.scaled(20), weight: .medium))
                            .foregroundStyle(Theme.textPrimary.opacity(0.8))
                        Text("Укажите параметры подключения")
                            .font(.system(size: Theme.fontCaption))
                            .foregroundStyle(Theme.accentMedium)
                    }
                    .padding(.top, Theme.scaled(24))
                    .padding(.bottom, Theme.scaled(4))
                }

                // Agent section
                settingsSection(title: "Агент") {
                    settingsField(icon: "person", label: "Имя") {
                        TextField("Jarvis", text: $settings.agentName)
                            .font(.system(size: Theme.fontSubhead))
                            .foregroundStyle(Theme.textPrimary)
                            .multilineTextAlignment(.trailing)
                            .tint(Theme.accent)
                    }
                }

                // Connection section
                settingsSection(title: "Подключение") {
                    settingsField(icon: "key", label: "Токен") {
                        SecureField("Bearer token", text: $settings.bearerToken)
                            .font(.system(size: Theme.fontSubhead))
                            .foregroundStyle(Theme.textPrimary)
                            .multilineTextAlignment(.trailing)
                            .textContentType(.none)
                            .tint(Theme.accent)
                    }
                }

                // Context section
                settingsSection(title: "Контекст") {
                    settingsToggle(icon: "location", label: "Геолокация", isOn: $settings.useLocation)
                    settingsDivider()
                    settingsToggle(icon: "heart", label: "Здоровье", isOn: $settings.useHealth)
                    settingsDivider()
                    settingsToggle(icon: "calendar", label: "Календарь", isOn: $settings.useCalendar)
                    settingsDivider()
                    settingsToggle(icon: "bell", label: "Уведомления", isOn: $settings.notificationsEnabled)
                }

                // Voice section
                if !isInitialSetup {
                    settingsSection(title: "Голос") {
                        settingsToggle(icon: "speaker.wave.2", label: "Озвучивать ответы на голос", isOn: $settings.autoSpeak)
                        settingsDivider()
                        settingsToggle(icon: "waveform", label: "Отвечать только голосом", isOn: $settings.voiceOnlyMode)
                    }
                }

                // Voice mode (Glass) section
                if !isInitialSetup {
                    settingsSection(title: "Голосовой режим") {
                        settingsToggle(icon: "arrow.clockwise.circle",
                                       label: "Авто-возобновление слушания",
                                       isOn: $settings.autoResumeListening)
                        settingsDivider()
                        settingsToggle(icon: "hand.tap",
                                       label: "Зажать орб для записи",
                                       isOn: $settings.pushToTalk)
                        settingsDivider()
                        HStack(spacing: Theme.scaled(10)) {
                            Image(systemName: "timer")
                                .font(.system(size: Theme.fontCaption))
                                .foregroundStyle(Theme.accentMedium)
                                .frame(width: Theme.scaled(20))
                            Text("Тайм-аут тишины")
                                .font(.system(size: Theme.fontSubhead))
                                .foregroundStyle(Theme.textSecondary)
                            Spacer()
                            Picker("Тайм-аут тишины",
                                   selection: Binding(
                                    get: { settings.silenceTimeoutSec },
                                    set: { settings.silenceTimeoutSec = $0 })) {
                                Text("15 с").tag(15)
                                Text("30 с").tag(30)
                                Text("60 с").tag(60)
                            }
                            .pickerStyle(.segmented)
                            .frame(maxWidth: Theme.scaled(180))
                            .labelsHidden()
                        }
                        .padding(.horizontal, Theme.hPadding)
                        .frame(minHeight: Theme.minTapSize)
                    }
                }

                // Input section
                if !isInitialSetup {
                    settingsSection(title: "Ввод") {
                        settingsToggle(icon: "return", label: "Отправка по Enter", isOn: $settings.enterToSend)
                    }
                }

                // Apple Watch section
                if !isInitialSetup {
                    settingsSection(title: "Apple Watch") {
                        settingsToggle(
                            icon: "applewatch",
                            label: "Слать ответы Джарвиса на часы",
                            isOn: $settings.watchCompanionEnabled
                        )
                    }
                }

                // ID платформы
                if !isInitialSetup {
                    settingsSection(title: "Система") {
                        HStack {
                            VStack(alignment: .leading, spacing: Theme.scaled(2)) {
                                Text("ID платформы")
                                    .font(.system(size: Theme.fontCaption))
                                    .foregroundStyle(Theme.textSecondary)
                                Text(settings.platformId)
                                    .font(.system(size: Theme.fontSmall, design: .monospaced))
                                    .foregroundStyle(Theme.accentMedium)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Button {
                                UIPasteboard.general.string = settings.platformId
                            } label: {
                                Image(systemName: "doc.on.doc")
                                    .font(.system(size: Theme.fontCaption))
                                    .foregroundStyle(Theme.accentMedium)
                                    .frame(width: Theme.minTapSize, height: Theme.minTapSize)
                            }
                        }
                        .padding(.horizontal, Theme.hPadding)
                        .padding(.vertical, Theme.scaled(8))
                    }
                }
                // About
                if !isInitialSetup {
                    settingsSection(title: "О приложении") {
                        HStack {
                            VStack(alignment: .leading, spacing: Theme.scaled(2)) {
                                Text("Jarvis")
                                    .font(.system(size: Theme.fontSubhead, weight: .medium))
                                    .foregroundStyle(Theme.textPrimary.opacity(0.7))
                                Text("Версия \(appVersion) (\(buildNumber))")
                                    .font(.system(size: Theme.fontSmall))
                                    .foregroundStyle(Theme.accentMedium)
                            }
                            Spacer()
                            Image(systemName: "info.circle")
                                .font(.system(size: Theme.fontCaption))
                                .foregroundStyle(Theme.accentMedium)
                        }
                        .padding(.horizontal, Theme.hPadding)
                        .padding(.vertical, Theme.scaled(12))
                    }
                }
            }
            .padding(.horizontal, Theme.hPadding)
            .padding(.top, isInitialSetup ? 0 : Theme.scaled(16))
            .padding(.bottom, Theme.scaled(32))
        }
    }

    // MARK: – Components

    private func settingsSection(title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title.uppercased())
                .font(.system(size: Theme.fontSmall, weight: .medium))
                .tracking(1)
                .foregroundStyle(Theme.accentMedium)
                .padding(.bottom, Theme.scaled(8))
                .padding(.leading, Theme.scaled(4))

            VStack(spacing: 0) {
                content()
            }
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cardRadius)
                    .stroke(Theme.surfaceBorder, lineWidth: 0.5)
            )
        }
    }

    private func settingsField(icon: String, label: String, @ViewBuilder field: () -> some View) -> some View {
        HStack(spacing: Theme.scaled(10)) {
            Image(systemName: icon)
                .font(.system(size: Theme.fontCaption))
                .foregroundStyle(Theme.accentMedium)
                .frame(width: Theme.scaled(20))
            Text(label)
                .font(.system(size: Theme.fontSubhead))
                .foregroundStyle(Theme.textSecondary)
            Spacer()
            field()
        }
        .padding(.horizontal, Theme.hPadding)
        .frame(minHeight: Theme.minTapSize)
    }

    private func settingsToggle(icon: String, label: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: Theme.scaled(10)) {
            Image(systemName: icon)
                .font(.system(size: Theme.fontCaption))
                .foregroundStyle(Theme.accentMedium)
                .frame(width: Theme.scaled(20))
            Text(label)
                .font(.system(size: Theme.fontSubhead))
                .foregroundStyle(Theme.textSecondary)
            Spacer()
            Toggle("", isOn: isOn)
                .labelsHidden()
                .tint(Theme.accent)
        }
        .padding(.horizontal, Theme.hPadding)
        .frame(minHeight: Theme.minTapSize)
    }

    private func settingsDivider() -> some View {
        Divider()
            .background(Theme.accent.opacity(0.06))
            .padding(.leading, Theme.scaled(46))
    }
}

struct SettingsView: View {
    let isInitialSetup: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if !isInitialSetup {
                    header
                }
                SettingsFormBody(isInitialSetup: isInitialSetup)
            }
            .background(Theme.background.ignoresSafeArea())
            .preferredColorScheme(.dark)
            .toolbar(.hidden, for: .navigationBar)
        }
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
            Text("Настройки")
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
