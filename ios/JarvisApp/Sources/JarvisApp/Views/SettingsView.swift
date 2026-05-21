import AVFoundation
import SwiftUI

struct SettingsView: View {
    let isInitialSetup: Bool
    @EnvironmentObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @StateObject private var previewSynth = SpeechSynthesizer()

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }
    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            if !isInitialSetup {
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

            ScrollView {
                VStack(spacing: Theme.scaled(20)) {
                    if isInitialSetup {
                        // Setup header
                        VStack(spacing: Theme.scaled(8)) {
                            OrbView(size: Theme.scaled(80), brightness: 0.6)
                            Text("Настройка")
                                .font(.system(size: Theme.scaled(20), weight: .medium))
                                .foregroundStyle(Theme.textPrimary.opacity(0.8))
                            Text("Укажи параметры подключения")
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
                        settingsField(icon: "network", label: "Сервер") {
                            TextField("100.x.x.x:3001", text: $settings.serverURL)
                                .font(.system(size: Theme.fontSubhead))
                                .foregroundStyle(Theme.textPrimary)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                                .multilineTextAlignment(.trailing)
                                .tint(Theme.accent)
                        }
                        settingsDivider()
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
                    }

                    // Voice section
                    if !isInitialSetup {
                        settingsSection(title: "Голос") {
                            settingsToggle(icon: "speaker.wave.2", label: "Озвучивать ответы на голос", isOn: $settings.autoSpeak)
                            let voices = SpeechSynthesizer.russianVoices()
                            if voices.isEmpty {
                                settingsDivider()
                                Text("Русские голоса не найдены. Добавьте в Настройках iOS → Универсальный доступ → Контент с озвучиванием → Голоса.")
                                    .font(.system(size: Theme.fontSmall))
                                    .foregroundStyle(Theme.textSecondary)
                                    .padding(.horizontal, Theme.hPadding)
                                    .padding(.vertical, Theme.scaled(10))
                            } else {
                                ForEach(voices, id: \.identifier) { v in
                                    settingsDivider()
                                    voiceRow(v)
                                }
                                settingsDivider()
                                voiceSlider(icon: "tortoise", label: "Скорость", value: $settings.voiceRate, range: 0.30...0.60)
                                settingsDivider()
                                voiceSlider(icon: "waveform.path", label: "Тон", value: $settings.voicePitch, range: 0.70...1.20)
                            }
                        }
                    }

                    // Input section
                    if !isInitialSetup {
                        settingsSection(title: "Ввод") {
                            settingsToggle(icon: "return", label: "Отправка по Enter", isOn: $settings.enterToSend)
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
        .background(Theme.background.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .navigationBarHidden(true)
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

    private func voiceLabel(_ v: AVSpeechSynthesisVoice) -> String {
        let quality: String
        switch v.quality {
        case .premium:  quality = "Premium"
        case .enhanced: quality = "Enhanced"
        default:        quality = "Compact"
        }
        return "\(v.name) · \(quality)"
    }

    @ViewBuilder
    private func voiceRow(_ v: AVSpeechSynthesisVoice) -> some View {
        let selected = settings.voiceId == v.identifier
        Button {
            settings.voiceId = v.identifier
            previewSynth.speak("Добрый день, сэр. Чем могу быть полезен?", voiceId: v.identifier)
        } label: {
            HStack(spacing: Theme.scaled(10)) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: Theme.fontCaption))
                    .foregroundStyle(selected ? Theme.accent : Theme.accentMedium)
                    .frame(width: Theme.scaled(20))
                Text(voiceLabel(v))
                    .font(.system(size: Theme.fontSubhead))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Spacer()
                Image(systemName: "play.circle")
                    .font(.system(size: Theme.fontBody))
                    .foregroundStyle(Theme.accentMedium)
            }
            .padding(.horizontal, Theme.hPadding)
            .frame(minHeight: Theme.minTapSize)
        }
    }

    private func voiceSlider(icon: String, label: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        HStack(spacing: Theme.scaled(10)) {
            Image(systemName: icon)
                .font(.system(size: Theme.fontCaption))
                .foregroundStyle(Theme.accentMedium)
                .frame(width: Theme.scaled(20))
            Text(label)
                .font(.system(size: Theme.fontSubhead))
                .foregroundStyle(Theme.textSecondary)
            Slider(value: value, in: range) { editing in
                if !editing {
                    previewSynth.speak("Добрый день, сэр. Чем могу быть полезен?",
                                       voiceId: settings.voiceId,
                                       rate: settings.voiceRate,
                                       pitch: settings.voicePitch)
                }
            }
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
