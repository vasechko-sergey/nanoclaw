import SwiftUI

struct SettingsView: View {
    let isInitialSetup: Bool
    @EnvironmentObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section("Агент") {
                LabeledContent("Имя") {
                    TextField("Jarvis", text: $settings.agentName)
                        .multilineTextAlignment(.trailing)
                }
            }

            Section("Подключение") {
                LabeledContent("URL сервера") {
                    TextField("100.x.x.x:3001", text: $settings.serverURL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("Токен") {
                    SecureField("Bearer token", text: $settings.bearerToken)
                        .multilineTextAlignment(.trailing)
                }
            }

            Section("Контекст") {
                Toggle("Геолокация", isOn: $settings.useLocation)
                Toggle("Здоровье и активность", isOn: $settings.useHealth)
            }

            Section {
                TextEditor(text: $settings.customContext)
                    .frame(minHeight: 80)
            } header: {
                Text("Заметки (по одной на строку)")
            } footer: {
                Text("Передаются агенту с каждым сообщением")
            }

            if !isInitialSetup {
                Section {
                    Text(settings.platformId)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Platform ID (для wiring в NanoClaw)")
                }
            }
        }
        .navigationTitle(isInitialSetup ? "Настройка" : "Настройки")
        .toolbar {
            if !isInitialSetup {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Готово") { dismiss() }
                }
            }
        }
    }
}
