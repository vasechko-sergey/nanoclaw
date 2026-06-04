import SwiftUI

/// Single-`ScrollView` right drawer with three sections: Profile, Context,
/// Settings. The left drawer (conversation list) was removed when Jarvis
/// became a single-chat assistant; this is now the only side drawer.
struct RightDrawerContent: View {
    @Environment(AppSettings.self) var settings
    let isConnected: Bool
    var onReconnect: () -> Void

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                // Header with title
                header

                // PROFILE
                sectionHeader("Профиль")
                ProfileFormBody(isConnected: isConnected, onReconnect: onReconnect)
                    .padding(.bottom, Theme.scaled(12))

                // CONTEXT — proactive triggers
                sectionHeader("Контекст")
                VStack(alignment: .leading, spacing: Theme.scaled(10)) {
                    @Bindable var s = settings
                    Toggle("Уведомлять о смене места", isOn: $s.proactiveGeofence)
                    Toggle("Замечать всплески пульса", isOn: $s.proactiveHealthHR)
                    Toggle("Сигналить о пробуждении", isOn: $s.proactiveHealthSleep)
                    Toggle("После тренировки — поздравление", isOn: $s.proactiveHealthWorkout)
                    Toggle("За 15 мин до события календаря", isOn: $s.proactiveCalendarWarn)
                }
                .toggleStyle(.switch)
                .tint(Theme.accent)
                .padding(.horizontal, Theme.hPadding)
                .padding(.bottom, Theme.scaled(12))

                // SETTINGS
                sectionHeader("Настройки")
                SettingsFormBody()
                    .padding(.bottom, Theme.scaled(20))
            }
        }
        .background(Color(red: 0.04, green: 0.08, blue: 0.11))
        .accessibilityIdentifier("right-drawer")
    }

    private var header: some View {
        HStack {
            Text("Профиль и настройки")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Theme.textPrimary.opacity(0.85))
            Spacer()
        }
        .padding(.horizontal, Theme.hPadding)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(Theme.metaFont)
            .tracking(1)
            .foregroundStyle(Theme.accentMedium)
            .padding(.horizontal, Theme.hPadding)
            .padding(.top, Theme.scaled(14))
            .padding(.bottom, Theme.scaled(6))
            .frame(maxWidth: .infinity, alignment: .leading)
    }

}
